import AppKit
import PierKit

/// 模型变化的广播：一个 tab 里的操作同步到显示同一文件夹的其他 tab
enum ModelEvents {
    /// userInfo: "deviceID": String（MTPDevice.id），"objects": [MTPObject]
    static let objectsAdded = Notification.Name("work.xiaolin.Pier.objectsAdded")
    /// userInfo: "deviceID": String，"handles": Set<UInt32>
    static let objectsRemoved = Notification.Name("work.xiaolin.Pier.objectsRemoved")
    /// userInfo: "deviceID": String，"object": MTPObject
    static let objectChanged = Notification.Name("work.xiaolin.Pier.objectChanged")

    @MainActor static func added(_ objects: [MTPObject], on deviceID: String) {
        NotificationCenter.default.post(name: objectsAdded, object: nil, userInfo: ["deviceID": deviceID, "objects": objects])
    }

    @MainActor static func removed(_ handles: Set<UInt32>, on deviceID: String) {
        NotificationCenter.default.post(name: objectsRemoved, object: nil, userInfo: ["deviceID": deviceID, "handles": handles])
    }

    @MainActor static func changed(_ object: MTPObject, on deviceID: String) {
        NotificationCenter.default.post(name: objectChanged, object: nil, userInfo: ["deviceID": deviceID, "object": object])
    }
}

/// DBI 移动之后不会更新目录列表（见 CONTEXT.md），这里记下本次会话里的移动，列目录时补上
@MainActor
enum MoveLedger {
    private static var movedIn: [String: [UInt32: [MTPObject]]] = [:]
    private static var movedOut: [String: [UInt32: Set<UInt32>]] = [:]

    static func record(_ object: MTPObject, from oldFolder: UInt32, to newFolder: UInt32, deviceID: String) {
        movedOut[deviceID, default: [:]][oldFolder, default: []].insert(object.handle)
        movedIn[deviceID, default: [:]][oldFolder]?.removeAll { $0.handle == object.handle }
        movedIn[deviceID, default: [:]][newFolder, default: []].append(object)
        movedOut[deviceID, default: [:]][newFolder]?.remove(object.handle)
    }

    /// 修正设备列出的某个文件夹内容
    static func apply(_ objects: [MTPObject], folder: UInt32, deviceID: String, final: Bool) -> [MTPObject] {
        let out = movedOut[deviceID]?[folder] ?? []
        var result = objects.filter { !out.contains($0.handle) }
        if final {
            let names = Set(result.map(\.name))
            result += (movedIn[deviceID]?[folder] ?? []).filter { !names.contains($0.name) }
        }
        return result
    }

    static func forget(deviceID: String) {
        movedIn[deviceID] = nil
        movedOut[deviceID] = nil
    }
}

/// 用户发起的文件操作：上传、下载、新建文件夹、改名、删除、移动
@MainActor
enum FileOperations {
    // MARK: 冲突处理（Finder 风格）

    enum ConflictChoice { case replace, keepBoth, skip, stop }

    /// 询问同名冲突怎么处理。`exact` 为 false 表示只是按设备规则冲突（名字不同），此时不能"替换"。
    static func askConflict(name: String, existing: String, exact: Bool, destination: String,
                            remaining: Int, applyToAll: inout Bool) -> ConflictChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if exact {
            alert.messageText = String(localized: "“\(destination)”中已存在名为“\(name)”的项目。")
            alert.informativeText = String(localized: "要替换它吗？替换后原项目会被删除。")
            alert.addButton(withTitle: String(localized: "保留两者"))
            alert.addButton(withTitle: String(localized: "停止"))
            alert.addButton(withTitle: String(localized: "替换"))
            alert.addButton(withTitle: String(localized: "跳过"))
        } else {
            alert.messageText = String(localized: "“\(name)”与“\(existing)”冲突。")
            alert.informativeText = String(localized: "这台设备判断重名时会忽略中文等非 ASCII 字符，两者不能放在同一个文件夹里。")
            alert.addButton(withTitle: String(localized: "保留两者"))
            alert.addButton(withTitle: String(localized: "停止"))
            alert.addButton(withTitle: String(localized: "跳过"))
        }
        if remaining > 0 {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = String(localized: "应用到全部")
        }
        let response = alert.runModal()
        applyToAll = alert.suppressionButton?.state == .on
        switch response {
        case .alertFirstButtonReturn: return .keepBoth
        case .alertSecondButtonReturn: return .stop
        case .alertThirdButtonReturn: return exact ? .replace : .skip
        default: return .skip
        }
    }

    /// 本地已有同名项目时生成"名称 2.ext"
    static func uniqueLocalURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) || fm.fileExists(atPath: TransferQueueTemp.url(for: url).path) else { return url }
        let dir = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        for i in 2... {
            let candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)")
            if !fm.fileExists(atPath: candidate.path) && !fm.fileExists(atPath: TransferQueueTemp.url(for: candidate).path) {
                return candidate
            }
        }
        return url
    }

    // MARK: 上传

    /// 把本地文件 / 文件夹上传到设备上的某个文件夹
    static func upload(_ urls: [URL], to location: BrowserLocation, knownSiblings: [String]? = nil, window: NSWindow?) async {
        guard !urls.isEmpty, let (device, storage) = location.resolved, let session = device.session else { return }
        if storage.isReadOnly {
            showMessage(String(localized: "“\(storage.displayName)”是只读的。"), detail: String(localized: "不能往这个存储里放文件。"), window: window)
            return
        }
        var siblings: [String]
        if let knownSiblings {
            siblings = knownSiblings
        } else {
            do {
                siblings = try await session.children(storage: location.storageID, parent: location.folderHandle, priority: .interactive).map(\.name)
            } catch {
                showError(error, window: window)
                return
            }
        }
        let quirks = session.quirks
        let destination = location.title
        var remembered: ConflictChoice?
        var plans: [(URL, String, Bool)] = []
        for (index, url) in urls.enumerated() {
            var name = url.lastPathComponent
            var replace = false
            if let existing = siblings.first(where: { quirks.collisionKey($0) == quirks.collisionKey(name) }) {
                let exact = existing.lowercased() == name.lowercased()
                var choice: ConflictChoice
                if let remembered, exact || remembered != .replace {
                    choice = remembered
                } else {
                    var all = false
                    choice = askConflict(name: name, existing: existing, exact: exact, destination: destination,
                                         remaining: urls.count - index - 1, applyToAll: &all)
                    if all { remembered = choice }
                }
                if !exact && choice == .replace { choice = .keepBoth }
                switch choice {
                case .stop: return
                case .skip: continue
                case .replace: replace = true
                case .keepBoth: name = quirks.uniqueName(for: name, siblings: siblings)
                }
            }
            if let problem = quirks.problem(with: name, purpose: .create, siblings: replace ? [] : siblings) {
                showMessage(String(localized: "无法上传“\(url.lastPathComponent)”。"), detail: problem, window: window)
                continue
            }
            siblings.append(name)
            plans.append((url, name, replace))
        }

        if quirks.isInstallTarget(storage), plans.contains(where: { fileSize($0.0) > UInt64(session.maxOutDataLength) }) {
            // 安装存储上的分段写还没验证过，提前提醒
            let alert = NSAlert()
            alert.messageText = String(localized: "有超过 4 GB 的文件")
            alert.informativeText = String(localized: "往 DBI 的安装存储写入超过 4 GB 的文件需要分段写入，DBI 是否支持还没有验证。如果安装失败，请改用 DBI 的其他安装方式。")
            alert.addButton(withTitle: String(localized: "继续上传"))
            alert.addButton(withTitle: String(localized: "取消"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        for (url, name, replace) in plans {
            let t = Services.transfers.upload(url, to: location.path, storageID: location.storageID, deviceID: device.persistentID,
                                              deviceName: device.name, as: name, replaceExisting: replace)
            let deviceID = device.id
            t.onFinish { t in
                guard t.state == .completed, let object = t.createdObject else { return }
                ModelEvents.added([object], on: deviceID)
            }
        }
    }

    private static func fileSize(_ url: URL) -> UInt64 {
        UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    // MARK: 下载

    /// 选择下载位置
    static func chooseDownloadFolder(window: NSWindow?, completion: @escaping @MainActor (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "下载")
        panel.message = String(localized: "选择下载位置")
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { completion(url) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { panel.begin(completionHandler: handler) }
    }

    static func download(_ items: [RemoteItemReference], to directory: URL) {
        var remembered: ConflictChoice?
        for (index, item) in items.enumerated() {
            guard let device = DeviceManager.shared.readyDevice(persistentID: item.persistentID) else { continue }
            var target = directory.appendingPathComponent(item.name, isDirectory: item.isFolder)
            var replace = false
            if FileManager.default.fileExists(atPath: target.path) {
                var choice: ConflictChoice
                if let remembered {
                    choice = remembered
                } else {
                    var all = false
                    choice = askConflict(name: item.name, existing: item.name, exact: true, destination: directory.lastPathComponent,
                                         remaining: items.count - index - 1, applyToAll: &all)
                    if all { remembered = choice }
                }
                switch choice {
                case .stop: return
                case .skip: continue
                case .replace: replace = true
                case .keepBoth: target = uniqueLocalURL(target)
                }
            }
            Services.transfers.download(item.object, from: item.folderPath, deviceID: device.persistentID, deviceName: device.name,
                                        to: target, replaceExisting: replace)
        }
    }

    // MARK: 新建 / 改名 / 删除 / 移动

    /// 在当前文件夹（或展开的子文件夹 `parent`）里新建文件夹，返回新节点
    static func createFolder(in contents: FolderContents, parent: FileNode?, window: NSWindow?) async -> FileNode? {
        guard let location = contents.location, let device = contents.device, let session = device.session,
              let storage = contents.storage else { return nil }
        if storage.isReadOnly {
            showMessage(String(localized: "“\(storage.displayName)”是只读的。"), detail: nil, window: window)
            return nil
        }
        let quirks = session.quirks
        let parentHandle = parent?.object.handle ?? location.folderHandle
        let siblings: [String]
        if let known = contents.siblingNames(in: parent) {
            siblings = known
        } else {
            siblings = (try? await session.children(storage: location.storageID, parent: parentHandle, priority: .interactive).map(\.name)) ?? []
        }
        let name = quirks.uniqueName(for: quirks.untitledFolderName, siblings: siblings)
        do {
            let handle = try await session.createFolder(named: name, storage: location.storageID, parent: parentHandle)
            let object = MTPObject(handle: handle, storageID: location.storageID,
                                   parent: parentHandle == PTPHandle.root ? location.storageID : parentHandle,
                                   name: name, format: .association, size: 0, modified: nil)
            let node = contents.insert(object, in: parent)
            ModelEvents.added([object], on: device.id)
            return node
        } catch {
            showError(error, window: window)
            return nil
        }
    }

    /// 改名前的预检，返回问题描述（nil 表示可以）
    static func renameProblem(_ node: FileNode, to name: String, in contents: FolderContents) -> String? {
        guard let quirks = contents.quirks else { return nil }
        if !quirks.canRename { return String(localized: "这台设备不支持改名。") }
        let siblings = contents.siblingNames(in: node.parent) ?? []
        return quirks.problem(with: name, purpose: .rename, siblings: siblings, original: node.name)
    }

    static func rename(_ node: FileNode, to name: String, in contents: FolderContents, window: NSWindow?) async -> Bool {
        guard name != node.name, let device = contents.device, let session = device.session else { return false }
        if let problem = renameProblem(node, to: name, in: contents) {
            showMessage(String(localized: "不能使用名称“\(name)”。"), detail: problem, window: window)
            return false
        }
        do {
            try await session.rename(node.object.handle, to: name)
            contents.rename(node, to: name)
            ModelEvents.changed(node.object, on: device.id)
            return true
        } catch {
            showError(error, window: window)
            return false
        }
    }

    static func confirmAndDelete(_ nodes: [FileNode], in contents: FolderContents, window: NSWindow?) {
        guard !nodes.isEmpty, let device = contents.device, let session = device.session else { return }
        if contents.quirks?.canDelete == false {
            showMessage(String(localized: "这台设备不支持删除。"), detail: nil, window: window)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = nodes.count == 1
            ? String(localized: "要删除“\(nodes[0].name)”吗？")
            : String(localized: "要删除这 \(nodes.count) 个项目吗？")
        var info = String(localized: "项目会立即从设备上删除，无法撤销。")
        if nodes.contains(where: \.isFolder) { info += String(localized: "文件夹里的所有内容也会一并删除。") }
        alert.informativeText = info
        let delete = alert.addButton(withTitle: String(localized: "删除"))
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "取消"))

        let objects = nodes.map(\.object)
        let deviceID = device.id
        let perform: @MainActor () -> Void = {
            Task {
                var removed = Set<UInt32>()
                var failures: [String] = []
                for object in objects {
                    do {
                        try await session.delete(object.handle)
                        removed.insert(object.handle)
                    } catch let e as PTPError where e.responseCode == .invalidObjectHandle {
                        removed.insert(object.handle)   // 已经不在了
                    } catch {
                        failures.append("\(object.name)：\(TransferQueue.message(for: error))")
                    }
                }
                contents.remove(handles: removed)
                ModelEvents.removed(removed, on: deviceID)
                if !failures.isEmpty {
                    showMessage(String(localized: "有 \(failures.count) 个项目没能删除。"), detail: failures.joined(separator: "\n"), window: window)
                }
            }
        }
        if let window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { MainActor.assumeIsolated { perform() } }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            perform()
        }
    }

    /// 能不能把这些项目移动到 `target`。可以返回 nil，否则返回原因。
    static func moveProblem(_ items: [RemoteItemReference], to target: BrowserLocation) -> String? {
        guard let (device, _) = target.resolved, let quirks = device.quirks else { return String(localized: "设备未连接。") }
        guard quirks.canMove else { return String(localized: "这台设备不支持移动。") }
        if target.path.isEmpty { return String(localized: "不能移动到存储的根目录。") }
        for item in items {
            if item.deviceID != target.deviceID || item.storageID != target.storageID {
                return String(localized: "只能在同一个存储里移动。")
            }
            if target.path.contains(where: { $0.handle == item.handle }) { return String(localized: "不能把文件夹移到它自己里面。") }
            if item.folderPath.last?.handle == target.folderHandle { return String(localized: "已经在这个文件夹里了。") }
            if quirks.moveRequiresASCIIFileName && !item.isFolder && !item.name.unicodeScalars.allSatisfy(\.isASCII) {
                return String(localized: "这台设备不能移动名称含中文等非 ASCII 字符的文件（“\(item.name)”）。")
            }
        }
        return nil
    }

    static func move(_ items: [RemoteItemReference], to target: BrowserLocation, window: NSWindow?) async {
        if let problem = moveProblem(items, to: target) {
            showMessage(String(localized: "无法移动"), detail: problem, window: window)
            return
        }
        guard let (device, _) = target.resolved, let session = device.session else { return }
        let siblings = (try? await session.children(storage: target.storageID, parent: target.folderHandle, priority: .interactive).map(\.name)) ?? []
        var failures: [String] = []
        for item in items {
            if siblings.contains(where: { session.quirks.collisionKey($0) == session.quirks.collisionKey(item.name) }) {
                failures.append(String(localized: "\(item.name)：目标文件夹里已有同名项目"))
                continue
            }
            do {
                try await session.move(item.handle, toStorage: target.storageID, parent: target.folderHandle)
                var moved = item.object
                moved.parent = target.folderHandle
                if session.quirks.listingsGoStaleAfterMove {
                    MoveLedger.record(moved, from: item.folderPath.last?.handle ?? PTPHandle.root, to: target.folderHandle, deviceID: device.id)
                }
                ModelEvents.removed([item.handle], on: device.id)
                ModelEvents.added([moved], on: device.id)
            } catch {
                failures.append("\(item.name)：\(TransferQueue.message(for: error))")
            }
        }
        if !failures.isEmpty {
            showMessage(String(localized: "有 \(failures.count) 个项目没能移动。"), detail: failures.joined(separator: "\n"), window: window)
        }
    }

    // MARK: 提示

    static func showError(_ error: Error, window: NSWindow?) {
        if error is CancellationError { return }
        showMessage(String(localized: "操作失败"), detail: TransferQueue.message(for: error), window: window)
    }

    static func showMessage(_ title: String, detail: String?, window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail ?? ""
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

/// 下载临时文件的位置（和 TransferQueue 保持一致）
enum TransferQueueTemp {
    static func url(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".pierdownload")
    }
}

// MARK: - 拖放（列表、图标视图、路径栏、侧边栏共用）

extension FileOperations {
    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// 拖到设备上的某个文件夹：Pier 里的项目 = 移动，Finder 里的文件 = 上传
    static func dropOperation(_ info: NSDraggingInfo, into target: BrowserLocation) -> NSDragOperation {
        let pasteboard = info.draggingPasteboard
        let items = RemoteItemReference.read(from: pasteboard)
        if !items.isEmpty { return moveProblem(items, to: target) == nil ? .move : [] }
        guard pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]),
              let (_, storage) = target.resolved, !storage.isReadOnly else { return [] }
        return .copy
    }

    static func performDrop(_ info: NSDraggingInfo, into target: BrowserLocation, knownSiblings: [String]?, window: NSWindow?) -> Bool {
        let pasteboard = info.draggingPasteboard
        let items = RemoteItemReference.read(from: pasteboard)
        if !items.isEmpty {
            Task { await move(items, to: target, window: window) }
            return true
        }
        let urls = fileURLs(from: pasteboard)
        guard !urls.isEmpty else { return false }
        // 松手后先让拖拽动画结束，再弹冲突对话框
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                _ = Task { await upload(urls, to: target, knownSiblings: knownSiblings, window: window) }
            }
        }
        return true
    }
}
