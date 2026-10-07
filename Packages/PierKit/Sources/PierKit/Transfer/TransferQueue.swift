import Foundation
import os

private let log = Logger(subsystem: "work.xiaolin.Pier", category: "Transfer")

/// 传输队列：每台设备同一时刻只跑一个任务（PTP 本来就是串行的，并发只会互相拖慢），不同设备之间并行。
///
/// - 下载按块续传：先写到目标旁边的 `名字.pierdownload`，完成后原子改名。
/// - 设备断开时任务进入"等待设备"，同一台设备重新连接后自动继续。
/// - 未完成的任务保存到磁盘，重启 app 后以"已暂停"状态恢复。
@MainActor
public final class TransferQueue {
    /// 任务增删、状态变化
    public static let didChange = Notification.Name("work.xiaolin.Pier.transfersDidChange")
    /// 运行中任务的进度更新（约每秒 4 次）
    public static let progressDidUpdate = Notification.Name("work.xiaolin.Pier.transferProgressDidUpdate")
    /// 某个任务结束。userInfo["transfer"] 是那个 `Transfer`
    public static let transferDidFinish = Notification.Name("work.xiaolin.Pier.transferDidFinish")

    public struct DeviceContext {
        public var session: MTPSession
        public var storages: [MTPStorage]
        public var name: String

        public init(session: MTPSession, storages: [MTPStorage], name: String) {
            self.session = session
            self.storages = storages
            self.name = name
        }
    }

    /// 按设备持久标识取当前可用的会话；设备没连接或没就绪时返回 nil
    public typealias Provider = @MainActor (String) -> DeviceContext?

    public private(set) var transfers: [Transfer] = []

    private let provider: Provider
    private let storeURL: URL?
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var saveScheduled = false

    /// 小于这个大小的文件用 userInitiated 优先级（用户等着看结果），更大的用 background
    static let smallFileThreshold: UInt64 = 8 << 20

    public init(storeURL: URL?, provider: @escaping Provider) {
        self.storeURL = storeURL
        self.provider = provider
        load()
    }

    // MARK: 发起

    /// 下载一个对象（文件或文件夹）到 `url`（最终位置，包含文件名）
    @discardableResult
    public func download(_ object: MTPObject, from folder: [MTPPathComponent], deviceID: String, deviceName: String,
                         to url: URL, replaceExisting: Bool = false) -> Transfer {
        let t = Transfer(direction: .download, deviceID: deviceID, deviceName: deviceName, storageID: object.storageID,
                         remoteName: object.name, remoteFolder: folder, remoteHandle: object.handle, localURL: url,
                         isFolder: object.isFolder, replaceExisting: replaceExisting)
        add(t)
        return t
    }

    /// 上传本地文件或文件夹到设备上的 `folder`，在设备上命名为 `name`
    @discardableResult
    public func upload(_ url: URL, to folder: [MTPPathComponent], storageID: UInt32, deviceID: String, deviceName: String,
                       as name: String? = nil, replaceExisting: Bool = false) -> Transfer {
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let t = Transfer(direction: .upload, deviceID: deviceID, deviceName: deviceName, storageID: storageID,
                         remoteName: name ?? url.lastPathComponent, remoteFolder: folder, remoteHandle: nil, localURL: url,
                         isFolder: isFolder, replaceExisting: replaceExisting)
        add(t)
        return t
    }

    private func add(_ t: Transfer) {
        transfers.append(t)
        changed()
        schedule()
    }

    // MARK: 控制

    public func pause(_ t: Transfer) {
        guard t.state.isPending else { return }
        t.state = .paused
        t.task?.cancel()
        changed()
        schedule()
    }

    /// 继续已暂停的任务，或重试失败的任务
    public func resume(_ t: Transfer) {
        guard t.state == .paused || t.state.isFailed else { return }
        t.state = .waiting
        changed()
        schedule()
    }

    public func cancel(_ t: Transfer) {
        guard !t.state.isFinished else { return }
        t.state = .cancelled
        if let task = t.task {
            // 运行中的任务由 run() 收尾
            task.cancel()
            changed()
        } else {
            cleanUpCancelled(t)
            finish(t)
        }
    }

    /// 从列表里移除（运行中的会先取消）
    public func remove(_ t: Transfer) {
        if !t.state.isFinished { cancel(t) }
        transfers.removeAll { $0 === t }
        changed()
    }

    public func clearFinished() {
        transfers.removeAll { $0.state.isFinished }
        changed()
    }

    public func pauseAll() { transfers.filter(\.state.isPending).forEach(pause) }

    /// 设备列表变化时调用：断开的设备上的任务转入等待，重新连上的设备继续
    public func devicesDidChange() {
        for t in transfers where t.state == .waitingForDevice && provider(t.deviceID) != nil {
            t.state = .waiting
        }
        changed()
        schedule()
    }

    // MARK: 查询

    /// 还在进行或等着进行的任务（退出前提醒用）
    public var pendingTransfers: [Transfer] { transfers.filter(\.state.isPending) }

    /// 所有未结束任务的总进度
    public var overallProgress: (fraction: Double, count: Int) {
        let active = transfers.filter { $0.state.isPending || $0.state == .paused }
        guard !active.isEmpty else { return (0, 0) }
        var total: UInt64 = 0, done: UInt64 = 0
        for t in active {
            let s = t.progress.snapshot
            total += s.totalBytes
            done += min(s.completedBytes, s.totalBytes)
        }
        return (total > 0 ? Double(done) / Double(total) : 0, active.count)
    }

    // MARK: 调度

    private func schedule() {
        var busyDevices = Set(transfers.filter { $0.task != nil }.map(\.deviceID))
        for t in transfers where t.state == .waiting && !busyDevices.contains(t.deviceID) {
            guard let context = provider(t.deviceID) else {
                t.state = .waitingForDevice
                continue
            }
            busyDevices.insert(t.deviceID)
            t.deviceName = context.name
            t.task = Task { [weak self] in
                await self?.run(t, context)
            }
        }
        updateTimerAndActivity()
        changed()
    }

    private func run(_ t: Transfer, _ context: DeviceContext) async {
        do {
            let sameSession = t.sessionID == ObjectIdentifier(context.session)
            if t.entries == nil || !sameSession {
                t.state = .preparing
                changed()
                switch t.direction {
                case .download: try await prepareDownload(t, context)
                case .upload: try await prepareUpload(t, context)
                }
            }
            t.recomputeProgress()
            try Task.checkCancellation()
            t.state = .running
            changed()
            switch t.direction {
            case .download: try await runDownload(t, context)
            case .upload: try await runUpload(t, context)
            }
            t.state = .completed
            log.info("transfer done: \(t.name, privacy: .public)")
        } catch {
            if t.state == .paused || t.state == .cancelled {
                // 用户主动暂停 / 取消，保持原状态
            } else if provider(t.deviceID) == nil {
                t.state = .waitingForDevice
            } else if error is CancellationError {
                t.state = .paused
            } else {
                log.error("transfer failed: \(t.name, privacy: .public): \(String(describing: error), privacy: .public)")
                t.state = .failed(Self.message(for: error))
            }
        }
        t.task = nil
        if t.state == .cancelled { cleanUpCancelled(t) }
        if t.state.isFinished || t.state.isFailed { finish(t) }
        unpublish(t)
        schedule()
    }

    private func finish(_ t: Transfer) {
        unpublish(t)
        t.fireFinish()
        NotificationCenter.default.post(name: Self.transferDidFinish, object: self, userInfo: ["transfer": t])
        changed()
        schedule()
    }

    /// 给用户看的错误描述
    public static func message(for error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        if let e = error as? PTPError {
            switch e {
            case .timeout: return String(localized: "设备没有响应，请检查连接后重试。")
            case .transport, .sessionClosed: return String(localized: "与设备的连接中断了。")
            case let .response(code, _) where code == .storeFull: return String(localized: "设备存储空间已满。")
            case let .response(code, _) where code == .accessDenied: return String(localized: "设备拒绝了这个操作（存储可能是只读的）。")
            case let .response(code, _) where code == .operationNotSupported: return String(localized: "设备不支持这个操作。")
            case let .response(code, _) where code == .invalidObjectHandle: return String(localized: "项目已不存在，可能已被删除或移动。")
            default: return e.description
            }
        }
        return (error as NSError).localizedDescription
    }

    // MARK: 下载

    private func localURL(for entry: Transfer.Entry, in t: Transfer) -> URL {
        entry.path.dropFirst().reduce(t.localURL) { $0.appendingPathComponent($1, isDirectory: false) }
    }

    /// 下载中的临时文件：和目标放在同一目录，完成后原子改名。用可见的扩展名，Finder 能在上面显示进度。
    static func temporaryURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".pierdownload")
    }

    private func prepareDownload(_ t: Transfer, _ context: DeviceContext) async throws {
        let session = context.session
        var top: MTPObject?
        if t.sessionID == ObjectIdentifier(session), let h = t.remoteHandle,
           let o = try? await session.object(h, priority: .userInitiated), o.name == t.remoteName {
            top = o
        } else {
            let parent: UInt32
            if t.remoteFolder.isEmpty {
                parent = PTPHandle.root
            } else {
                guard let resolved = try await session.resolve(path: t.remoteFolder.map(\.name), storage: t.storageID, priority: .userInitiated)
                else { throw TransferError.notFound(t.remoteName) }
                t.remoteFolder = resolved
                parent = resolved.last!.handle
            }
            top = try await session.children(storage: t.storageID, parent: parent, priority: .userInitiated)
                .first { $0.name == t.remoteName }
        }
        guard let top else { throw TransferError.notFound(t.remoteName) }
        t.remoteHandle = top.handle

        var entries = [Transfer.Entry(path: [t.remoteName], isFolder: top.isFolder, size: top.size, handle: top.handle, done: false)]
        if top.isFolder {
            var queue: [(UInt32, [String])] = [(top.handle, [t.remoteName])]
            while !queue.isEmpty {
                try Task.checkCancellation()
                let (folder, path) = queue.removeFirst()
                for child in try await session.children(storage: t.storageID, parent: folder, priority: .background) {
                    let childPath = path + [child.name]
                    entries.append(.init(path: childPath, isFolder: child.isFolder, size: child.size, handle: child.handle, done: false))
                    if child.isFolder { queue.append((child.handle, childPath)) }
                }
            }
        }
        let done = Set((t.entries ?? []).filter(\.done).map(\.path))
        for i in entries.indices where done.contains(entries[i].path) { entries[i].done = true }

        if t.pendingReplace {
            if FileManager.default.fileExists(atPath: t.localURL.path) {
                try FileManager.default.trashItem(at: t.localURL, resultingItemURL: nil)
            }
            t.pendingReplace = false
        }
        t.entries = entries
        t.sessionID = ObjectIdentifier(session)
        save()
    }

    private func runDownload(_ t: Transfer, _ context: DeviceContext) async throws {
        let fm = FileManager.default
        publish(t)
        for i in t.entries!.indices {
            let entry = t.entries![i]
            guard !entry.done else { continue }
            try Task.checkCancellation()
            let url = localURL(for: entry, in: t)
            t.hasStarted = true
            if entry.isFolder {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                t.progress.setCurrent(entry.path.last ?? "")
                let temp = Self.temporaryURL(for: url)
                if !t.isFolder { publish(t, at: temp) }
                try await context.session.download(entry.handle!, size: entry.size, into: temp, progress: t.progress,
                                                   priority: entry.size <= Self.smallFileThreshold ? .userInitiated : .background)
                if fm.fileExists(atPath: url.path) {
                    _ = try fm.replaceItemAt(url, withItemAt: temp)
                } else {
                    try fm.moveItem(at: temp, to: url)
                }
                t.progress.fileCompleted()
            }
            t.entries![i].done = true
            save()
        }
    }

    private func cleanUpCancelled(_ t: Transfer) {
        guard t.direction == .download, let entries = t.entries else { return }
        for entry in entries where !entry.isFolder && !entry.done {
            try? FileManager.default.removeItem(at: Self.temporaryURL(for: localURL(for: entry, in: t)))
        }
    }

    // MARK: 上传

    private func prepareUpload(_ t: Transfer, _ context: DeviceContext) async throws {
        let session = context.session
        let quirks = session.quirks
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: t.localURL.path, isDirectory: &isDir) else { throw TransferError.notFound(t.localURL.lastPathComponent) }

        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let topSize = UInt64((try? t.localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        var entries = [Transfer.Entry(path: [t.remoteName], isFolder: isDir.boolValue, size: isDir.boolValue ? 0 : topSize, handle: nil, done: false)]
        var skipped: [String] = []
        if isDir.boolValue, let walker = fm.enumerator(at: t.localURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            let baseCount = t.localURL.standardizedFileURL.pathComponents.count
            // 同一文件夹里按设备规则判重；冲突的项目（及其内容）跳过
            var seenKeys: [[String]: Set<String>] = [:]
            var skippedPrefixes: [[String]] = []
            while let url = walker.nextObject() as? URL {
                let relative = Array(url.standardizedFileURL.pathComponents.dropFirst(baseCount))
                let path = [t.remoteName] + relative
                if skippedPrefixes.contains(where: { path.starts(with: $0) }) { continue }
                let values = try? url.resourceValues(forKeys: Set(keys))
                let folder = values?.isDirectory ?? false
                let parentPath = Array(path.dropLast())
                let key = quirks.collisionKey(path.last!)
                if seenKeys[parentPath, default: []].contains(key) {
                    skipped.append(relative.joined(separator: "/"))
                    if folder { skippedPrefixes.append(path) }
                    continue
                }
                seenKeys[parentPath, default: []].insert(key)
                entries.append(.init(path: path, isFolder: folder, size: folder ? 0 : UInt64(values?.fileSize ?? 0), handle: nil, done: false))
            }
        }

        // 目标文件夹
        let parent: UInt32
        if t.remoteFolder.isEmpty {
            parent = PTPHandle.root
        } else if t.sessionID == ObjectIdentifier(session) {
            parent = t.remoteFolder.last!.handle
        } else {
            guard let resolved = try await session.resolve(path: t.remoteFolder.map(\.name), storage: t.storageID, priority: .userInitiated)
            else { throw TransferError.notFound(t.remoteFolder.last?.name ?? "") }
            t.remoteFolder = resolved
            parent = resolved.last!.handle
        }

        var siblings = try await session.children(storage: t.storageID, parent: parent, priority: .userInitiated)
        if t.pendingReplace {
            if let existing = siblings.first(where: { $0.name == t.remoteName }) {
                try await session.delete(existing.handle)
                siblings.removeAll { $0.handle == existing.handle }
            }
            t.pendingReplace = false
        }
        if !t.hasStarted, let problem = quirks.problem(with: t.remoteName, purpose: .create, siblings: siblings.map(\.name)) {
            throw TransferError.nameConflict(problem)
        }

        let total = entries.reduce(0) { $0 + $1.size }
        if let storage = context.storages.first(where: { $0.id == t.storageID }), !quirks.freeSpaceIsCached,
           storage.info.maxCapacity > 0, total > storage.info.freeSpace {
            throw TransferError.insufficientSpace(needed: total, available: storage.info.freeSpace)
        }

        let old = Dictionary((t.entries ?? []).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        for i in entries.indices {
            guard let previous = old[entries[i].path], previous.done else { continue }
            entries[i].done = true
            // 句柄属于旧会话就不要了，用到时按名字重新查
            entries[i].handle = t.sessionID == ObjectIdentifier(session) ? previous.handle : nil
        }
        t.entries = entries
        t.skipped = skipped
        t.sessionID = ObjectIdentifier(session)
        save()
    }

    private func runUpload(_ t: Transfer, _ context: DeviceContext) async throws {
        let session = context.session
        let destination = t.remoteFolder.last?.handle ?? PTPHandle.root
        let storage = context.storages.first { $0.id == t.storageID }
        let preferChunked = session.quirks.prefersChunkedUpload && (storage.map(session.quirks.allowsChunkedUpload(to:)) ?? false)
        // DBI 安装存储：文件传完即被安装、不会留在设备上，所以不回读校验，也不把它当成新建的文件显示
        let installs = storage.map(session.quirks.isInstallTarget) ?? false

        var handles: [[String]: UInt32] = [:]
        for e in t.entries! where e.done { if let h = e.handle { handles[e.path] = h } }
        var listings: [UInt32: [MTPObject]] = [:]
        let resuming = t.hasStarted

        func listing(_ folder: UInt32) async throws -> [MTPObject] {
            if let cached = listings[folder] { return cached }
            let items = try await session.children(storage: t.storageID, parent: folder, priority: .userInitiated)
            listings[folder] = items
            return items
        }
        func folderHandle(_ path: [String]) async throws -> UInt32 {
            if path.isEmpty { return destination }
            if let h = handles[path] { return h }
            let parent = try await folderHandle(Array(path.dropLast()))
            guard let match = try await listing(parent).first(where: { $0.name == path.last && $0.isFolder }) else {
                throw TransferError.notFound(path.joined(separator: "/"))
            }
            handles[path] = match.handle
            return match.handle
        }

        for i in t.entries!.indices {
            let entry = t.entries![i]
            guard !entry.done else { continue }
            try Task.checkCancellation()
            let name = entry.path.last!
            let parent = try await folderHandle(Array(entry.path.dropLast()))
            // 之前开始过：上次可能已经建好了这个文件夹，或者留下了写了一半的文件
            let existing = resuming ? try await listing(parent).first(where: { $0.name == name }) : nil
            t.hasStarted = true

            let handle: UInt32
            if entry.isFolder {
                if let existing, existing.isFolder {
                    handle = existing.handle
                } else {
                    handle = try await session.createFolder(named: name, storage: t.storageID, parent: parent)
                    listings[handle] = []
                }
            } else {
                if let existing, !existing.isFolder { try await session.delete(existing.handle) }
                t.progress.setCurrent(name)
                let source = entry.path.dropFirst().reduce(t.localURL) { $0.appendingPathComponent($1) }
                handle = try await session.upload(file: source, name: name, storage: t.storageID, parent: parent,
                                                  progress: t.progress, preferChunked: preferChunked, verify: !installs,
                                                  priority: entry.size <= Self.smallFileThreshold ? .userInitiated : .background)
                t.progress.fileCompleted()
            }
            handles[entry.path] = handle
            t.entries![i].handle = handle
            t.entries![i].done = true
            if entry.path.count == 1, !installs {
                t.createdObject = MTPObject(handle: handle, storageID: t.storageID, parent: destination == PTPHandle.root ? t.storageID : destination,
                                            name: name, format: entry.isFolder ? .association : .undefined, size: entry.size, modified: nil)
            }
            save()
        }
        // 文件夹上传：完成时再确认一下顶层对象
        if t.createdObject == nil, !installs, let h = handles[[t.remoteName]] {
            t.createdObject = try? await session.object(h, priority: .userInitiated)
        }
    }

    // MARK: Finder 进度

    /// 在 Finder 里显示进度：文件夹显示在目标文件夹上，单个文件显示在 .pierdownload 临时文件上
    private func publish(_ t: Transfer, at url: URL? = nil) {
        guard t.direction == .download else { return }
        let target = url ?? (t.isFolder ? t.localURL : nil)
        guard let target else { return }
        if let existing = t.publishedProgress, existing.fileURL == target { return }
        unpublish(t)
        let p = Progress(totalUnitCount: Int64(clamping: t.progress.snapshot.totalBytes))
        p.kind = .file
        p.fileOperationKind = .downloading
        p.fileURL = target
        p.isCancellable = true
        let id = t.id
        p.cancellationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, let t = self.transfers.first(where: { $0.id == id }) else { return }
                self.cancel(t)
            }
        }
        p.publish()
        t.publishedProgress = p
    }

    private func unpublish(_ t: Transfer) {
        t.publishedProgress?.unpublish()
        t.publishedProgress = nil
    }

    // MARK: 定时刷新

    private func updateTimerAndActivity() {
        let running = transfers.contains { $0.task != nil }
        if running && timer == nil {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !running, let timer {
            timer.invalidate()
            self.timer = nil
            tick()
        }
        if running && activity == nil {
            // 传输期间不让系统空闲睡眠
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                             reason: String(localized: "正在传输文件"))
        } else if !running, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private func tick() {
        let now = Date()
        for t in transfers {
            guard t.task != nil else {
                t.bytesPerSecond = 0
                t.lastSample = nil
                continue
            }
            let snap = t.progress.snapshot
            if let last = t.lastSample {
                let dt = now.timeIntervalSince(last.time)
                if dt > 0.1 {
                    let instant = Double(snap.completedBytes &- min(last.bytes, snap.completedBytes)) / dt
                    // 指数平滑，避免数字乱跳
                    t.bytesPerSecond = t.bytesPerSecond == 0 ? instant : t.bytesPerSecond * 0.8 + instant * 0.2
                    t.lastSample = (now, snap.completedBytes)
                }
            } else {
                t.lastSample = (now, snap.completedBytes)
            }
            if let p = t.publishedProgress {
                p.totalUnitCount = Int64(clamping: snap.totalBytes)
                p.completedUnitCount = Int64(clamping: snap.completedBytes)
            }
        }
        NotificationCenter.default.post(name: Self.progressDidUpdate, object: self)
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
        save()
    }

    // MARK: 持久化

    /// 合并短时间内的多次保存
    private func save() {
        guard storeURL != nil, !saveScheduled else { return }
        saveScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.saveScheduled = false
            self?.saveNow()
        }
    }

    public func saveNow() {
        guard let storeURL else { return }
        let records = transfers.filter { !$0.state.isFinished }.map(\.record)
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: storeURL, options: .atomic)
        } catch {
            log.error("save transfers failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func load() {
        guard let storeURL, let data = try? Data(contentsOf: storeURL),
              let records = try? JSONDecoder().decode([Transfer.Record].self, from: data) else { return }
        transfers = records.map(Transfer.init(record:))
    }
}
