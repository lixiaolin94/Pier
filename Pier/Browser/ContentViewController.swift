import AppKit
import PierKit
import Quartz

/// 内容区：文件视图（列表 / 图标）+ 底部路径栏 + 状态栏；没有位置时显示占位提示。
/// 所有文件操作都在这里实现，两种视图共用。
@MainActor
final class ContentViewController: NSViewController {
    /// 和 Finder 一样的四种显示方式（顺序与工具栏、⌘1–⌘4 一致）
    enum ViewMode: String, CaseIterable { case icon, list, column, gallery }

    weak var browser: BrowserWindowController?

    let contents = FolderContents()
    private let views: [ViewMode: FileBrowsingView] = [
        .icon: IconViewController(), .list: FileListViewController(),
        .column: ColumnViewController(), .gallery: GalleryViewController(),
    ]
    private(set) var viewMode: ViewMode = .list
    private var currentView: FileBrowsingView { views[viewMode]! }

    private let fileContainer = NSView()
    private let pathControl = PathBarControl()
    private let pathBar = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusBar = NSView()
    private let placeholder = NSStackView()
    private let placeholderTitle = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let messageLabel = NSTextField(labelWithString: "")
    private var spinnerTask: Task<Void, Never>?
    private var transientStatus: String?

    private var location: BrowserLocation?
    private var previewNodes: [FileNode] = []
    private var previewPanel: QLPreviewPanel?

    private static let pathBarKey = "ShowPathBar"
    private static let statusBarKey = "ShowStatusBar"

    var isPathBarVisible: Bool { !pathBar.isHidden }
    var isStatusBarVisible: Bool { !statusBar.isHidden }

    override func loadView() {
        UserDefaults.standard.register(defaults: [Self.pathBarKey: true, Self.statusBarKey: true])
        let root = NSView()

        for mode in ViewMode.allCases {
            views[mode]!.host = self
            addChild(views[mode]!)
        }
        fileContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(fileContainer)

        // 路径栏（也是拖放目标）
        pathControl.pathStyle = .standard
        pathControl.controlSize = .small
        pathControl.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathControl.focusRingType = .none
        pathControl.target = self
        pathControl.action = #selector(pathItemClicked(_:))
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathControl.dropTarget = { [weak self] index in self?.locationForPathItem(index) }
        pathBar.addSubview(pathControl)
        addSeparator(to: pathBar)

        // 状态栏
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(statusLabel)
        addSeparator(to: statusBar)

        let bottom = NSStackView(views: [pathBar, statusBar])
        bottom.orientation = .vertical
        bottom.spacing = 0
        bottom.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bottom)

        // 加载中 / 空文件夹提示
        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(spinner)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.isHidden = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(messageLabel)

        // 未连接占位
        let icon = NSImageView(image: NSImage(systemSymbolName: "cable.connector", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 48, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        placeholderTitle.stringValue = String(localized: "未连接设备")
        placeholderTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        placeholderTitle.textColor = .secondaryLabelColor
        let hint = NSTextField(wrappingLabelWithString: String(localized: "用数据线连接 Android 设备，并在设备上选择「文件传输」（MTP）模式。如果 macOS 询问是否允许配件连接，请选择「允许」。"))
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.preferredMaxLayoutWidth = 320
        [icon, placeholderTitle, hint].forEach(placeholder.addArrangedSubview)
        placeholder.orientation = .vertical
        placeholder.spacing = 10
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(placeholder)

        NSLayoutConstraint.activate([
            fileContainer.topAnchor.constraint(equalTo: root.topAnchor),
            fileContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            fileContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            fileContainer.bottomAnchor.constraint(equalTo: bottom.topAnchor),

            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            pathBar.widthAnchor.constraint(equalTo: bottom.widthAnchor),
            statusBar.widthAnchor.constraint(equalTo: bottom.widthAnchor),
            pathBar.heightAnchor.constraint(equalToConstant: 24),
            statusBar.heightAnchor.constraint(equalToConstant: 22),

            pathControl.leadingAnchor.constraint(equalTo: pathBar.leadingAnchor, constant: 8),
            pathControl.trailingAnchor.constraint(lessThanOrEqualTo: pathBar.trailingAnchor, constant: -8),
            pathControl.centerYAnchor.constraint(equalTo: pathBar.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -8),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),

            spinner.centerXAnchor.constraint(equalTo: fileContainer.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: fileContainer.centerYAnchor),
            messageLabel.centerXAnchor.constraint(equalTo: fileContainer.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: fileContainer.centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: fileContainer.widthAnchor, constant: -40),

            placeholder.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -20),
        ])

        pathBar.isHidden = !UserDefaults.standard.bool(forKey: Self.pathBarKey)
        statusBar.isHidden = !UserDefaults.standard.bool(forKey: Self.statusBarKey)
        view = root

        contents.onChange = { [weak self] change in self?.contentsDidChange(change) }
        install(viewMode)
        NotificationCenter.default.addObserver(self, selector: #selector(devicesDidChange(_:)), name: DeviceManager.devicesDidChange, object: nil)
    }

    private func addSeparator(to bar: NSView) {
        let line = NSBox.separator()
        line.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(line)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: bar.topAnchor),
            line.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
        ])
    }

    // MARK: 视图模式

    private func install(_ mode: ViewMode) {
        let wasFocused = currentView.isViewLoaded && view.window?.firstResponder.map { ($0 as? NSView)?.isDescendant(of: currentView.view) ?? false } == true
        fileContainer.subviews.forEach { $0.removeFromSuperview() }
        viewMode = mode
        let v = currentView.view
        v.translatesAutoresizingMaskIntoConstraints = false
        fileContainer.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: fileContainer.topAnchor),
            v.leadingAnchor.constraint(equalTo: fileContainer.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: fileContainer.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: fileContainer.bottomAnchor),
        ])
        currentView.contentsDidChange(.reload)
        if wasFocused { currentView.focus() }
    }

    /// 切换列表 / 图标视图，并记住这个文件夹的选择
    func setViewMode(_ mode: ViewMode) {
        guard mode != viewMode else { return }
        let selection = currentView.selectedNodes
        install(mode)
        currentView.select(selection)
        ViewPreferences.set(mode, for: location?.stored)
        browser?.viewModeDidChange()
    }

    // MARK: 位置

    func show(_ location: BrowserLocation?, forceReload: Bool) {
        _ = view
        let changed = location != self.location
        self.location = location
        let hasLocation = location?.resolved != nil
        placeholder.isHidden = hasLocation
        fileContainer.isHidden = !hasLocation
        if changed {
            let mode = ViewPreferences.mode(for: location?.stored)
            if mode != viewMode { install(mode) }
            contents.grouping = ViewPreferences.grouping(for: location?.stored)
        }
        if changed || forceReload { contents.load(hasLocation ? location : nil) }
        updatePath()
        updateStatus()
    }

    /// 等待恢复的位置（设备还没连上）时，占位页显示的文字
    func setPlaceholder(_ title: String?) {
        _ = view
        placeholderTitle.stringValue = title ?? String(localized: "未连接设备")
    }

    @objc private func devicesDidChange(_ note: Notification) {
        // 存储容量可能刷新了
        updateStatus()
    }

    private func contentsDidChange(_ change: FolderContents.Change) {
        currentView.contentsDidChange(change)
        // 加载中的转圈延迟显示，避免快速加载时闪烁
        spinnerTask?.cancel()
        if contents.isLoading && contents.rootNodes.isEmpty {
            spinnerTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled, self.contents.isLoading, self.contents.rootNodes.isEmpty else { return }
                self.spinner.startAnimation(nil)
            }
        } else {
            spinner.stopAnimation(nil)
        }
        messageLabel.stringValue = contents.message ?? ""
        messageLabel.isHidden = contents.message == nil || !contents.rootNodes.isEmpty
        updateStatus()
        if case .reload = change, previewPanel != nil { refreshPreview() }
    }

    // MARK: 搜索

    /// 输入时只过滤当前文件夹；回车后在后台递归搜索
    func search(_ text: String, recursive: Bool) {
        if text.isEmpty {
            contents.filterText = ""
            contents.endSearch()
        } else if recursive {
            contents.filterText = ""
            contents.search(text)
        } else {
            if contents.searchQuery != nil { contents.endSearch() }
            contents.filterText = text
        }
    }

    // MARK: 路径栏

    private func updatePath() {
        guard let location, let (device, storage) = location.resolved else {
            pathControl.pathItems = []
            return
        }
        var items: [NSPathControlItem] = []
        func add(_ title: String, _ image: NSImage?) {
            let item = NSPathControlItem()
            item.title = title
            item.image = image
            items.append(item)
        }
        add(device.name, NSImage(systemSymbolName: "candybarphone", accessibilityDescription: nil))
        add(storage.displayName, NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil))
        for folder in location.path { add(folder.name, FileTypes.icon(forName: folder.name, isFolder: true)) }
        pathControl.pathItems = items
    }

    /// 路径栏第 index 项对应的位置（0 = 设备，没有位置）
    private func locationForPathItem(_ index: Int) -> BrowserLocation? {
        guard index >= 1, var target = location else { return nil }
        target.path = Array(target.path.prefix(index - 1))
        return target
    }

    @objc private func pathItemClicked(_ sender: NSPathControl) {
        guard let clicked = sender.clickedPathItem, let index = sender.pathItems.firstIndex(of: clicked),
              let target = locationForPathItem(max(index, 1)) else { return }
        browser?.navigate(to: target)
    }

    // MARK: 状态栏

    private func updateStatus() {
        guard let (device, storage) = location?.resolved else {
            statusLabel.stringValue = ""
            return
        }
        var parts: [String] = []
        if let transientStatus { parts.append(transientStatus) }
        let count = contents.displayedNodes.count
        let selected = currentView.isViewLoaded ? currentView.selectedNodes.count : 0
        if contents.isLoading {
            parts.append(contents.searchQuery != nil
                         ? String(localized: "正在搜索…（找到 \(count) 项）")
                         : String(localized: "正在读取…（\(count) 项）"))
        } else if selected > 0 {
            parts.append(String(localized: "已选择 \(selected) 项，共 \(count) 项"))
        } else {
            parts.append(contents.searchQuery != nil ? String(localized: "找到 \(count) 项") : String(localized: "\(count) 项"))
        }
        // DBI 的剩余空间是连接时的缓存值：数字前加"约"，说明放在悬停提示里
        if device.quirks?.freeSpaceIsCached == true {
            parts.append(String(localized: "约 \(Format.bytes(storage.info.freeSpace)) 可用"))
            statusLabel.toolTip = String(localized: "这台设备只在连接时报告一次剩余空间，传输后不会更新。")
        } else {
            parts.append(String(localized: "\(Format.bytes(storage.info.freeSpace)) 可用"))
            statusLabel.toolTip = nil
        }
        if storage.isReadOnly { parts.append(String(localized: "只读")) }
        statusLabel.stringValue = parts.joined(separator: "，")
    }

    private func flashStatus(_ text: String?) {
        transientStatus = text
        updateStatus()
    }

    func togglePathBar() {
        pathBar.isHidden.toggle()
        UserDefaults.standard.set(!pathBar.isHidden, forKey: Self.pathBarKey)
    }

    func toggleStatusBar() {
        statusBar.isHidden.toggle()
        UserDefaults.standard.set(!statusBar.isHidden, forKey: Self.statusBarKey)
    }

    // MARK: 辅助

    private var device: MTPDevice? { contents.device }
    private var storage: MTPStorage? { contents.storage }
    private var isWritable: Bool { storage.map { !$0.isReadOnly } ?? false }
    private var actionNodes: [FileNode] { currentView.isViewLoaded ? currentView.actionNodes : [] }

    private func location(of node: FileNode) -> BrowserLocation? {
        guard let location else { return nil }
        var l = location
        l.path = node.isFolder ? node.path : node.folderPath
        return l
    }

    private func references(_ nodes: [FileNode]) -> [RemoteItemReference] {
        guard let device else { return [] }
        return nodes.map { RemoteItemReference(node: $0, device: device) }
    }
}

// MARK: - FileViewHost

extension ContentViewController: FileViewHost {
    func open(_ node: FileNode, inNewTab: Bool) {
        if node.isFolder {
            guard let target = location(of: node) else { return }
            if inNewTab { browser?.openInNewTab(target) } else { browser?.navigate(to: target) }
            return
        }
        guard let device else { return }
        // 先下载到缓存，再用默认 app 打开
        flashStatus(String(localized: "正在打开“\(node.name)”…"))
        let object = node.object
        Task { [weak self] in
            do {
                let url = try await LocalCopies.shared.fetch(object, on: device, priority: .interactive)
                NSWorkspace.shared.open(url)
            } catch {
                FileOperations.showError(error, window: self?.view.window)
            }
            self?.flashStatus(nil)
        }
    }

    func selectionDidChange() {
        updateStatus()
        if previewPanel != nil { refreshPreview() }
    }

    func populateContextMenu(_ menu: NSMenu, for nodes: [FileNode]) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        guard !nodes.isEmpty else {
            add(String(localized: "新建文件夹"), #selector(newFolder(_:)))
            add(String(localized: "上传…"), #selector(upload(_:)))
            add(String(localized: "粘贴"), #selector(paste(_:)))
            menu.addItem(.separator())
            add(String(localized: "刷新"), #selector(reload(_:)))
            return
        }
        add(String(localized: "打开"), #selector(openSelection(_:)))
        if nodes.contains(where: \.isFolder) { add(String(localized: "在新标签页中打开"), #selector(openSelectionInNewTab(_:))) }
        if contents.searchQuery != nil { add(String(localized: "显示所在文件夹"), #selector(showEnclosingFolder(_:))) }
        menu.addItem(.separator())
        add(String(localized: "下载到…"), #selector(downloadSelection(_:)))
        add(String(localized: "快速查看"), #selector(quickLook(_:)))
        add(String(localized: "显示简介"), #selector(getInfo(_:)))
        add(String(localized: "重新命名"), #selector(renameSelection(_:)))
        menu.addItem(.separator())
        add(String(localized: "拷贝"), #selector(copy(_:)))
        menu.addItem(.separator())
        add(String(localized: "删除"), #selector(deleteSelection(_:)))
    }

    func pasteboardWriter(for node: FileNode) -> NSPasteboardWriting? {
        guard let device else { return nil }
        return RemoteFilePromiseProvider(reference: RemoteItemReference(node: node, device: device))
    }

    func validateDrop(_ info: NSDraggingInfo, onto node: FileNode?) -> NSDragOperation {
        guard let target = node.flatMap(location(of:)) ?? (contents.searchQuery == nil ? location : nil) else { return [] }
        return FileOperations.dropOperation(info, into: target)
    }

    func acceptDrop(_ info: NSDraggingInfo, onto node: FileNode?) -> Bool {
        guard let target = node.flatMap(location(of:)) ?? location else { return false }
        let siblings = node == nil ? contents.siblingNames(in: nil) : node?.children?.map(\.name)
        return FileOperations.performDrop(info, into: target, knownSiblings: siblings, window: view.window)
    }

    func renameProblem(_ node: FileNode, to name: String) -> String? {
        FileOperations.renameProblem(node, to: name, in: contents)
    }

    func commitRename(_ node: FileNode, to name: String) {
        Task { [weak self] in
            guard let self else { return }
            if await FileOperations.rename(node, to: name, in: contents, window: view.window) {
                currentView.select([node])
            }
        }
    }
}

// MARK: - 动作（响应链）

extension ContentViewController: BrowserActions, NSMenuItemValidation {
    @objc func openSelection(_ sender: Any?) {
        let nodes = actionNodes
        // 多选时文件夹只打开第一个（Finder 会开多个窗口，这里保持简单）
        if let folder = nodes.first(where: \.isFolder) { open(folder, inNewTab: false) }
        nodes.filter { !$0.isFolder }.forEach { open($0, inNewTab: false) }
    }

    @objc func openSelectionInNewTab(_ sender: Any?) {
        actionNodes.filter(\.isFolder).forEach { open($0, inNewTab: true) }
    }

    @objc func showEnclosingFolder(_ sender: Any?) {
        guard let node = actionNodes.first, var target = location else { return }
        target.path = node.folderPath
        browser?.navigate(to: target)
    }

    @objc func newFolder(_ sender: Any?) {
        Task { [weak self] in
            guard let self, let node = await FileOperations.createFolder(in: contents, parent: nil, window: view.window) else { return }
            currentView.select([node])
            currentView.beginRename(node)
        }
    }

    @objc func renameSelection(_ sender: Any?) {
        guard let node = actionNodes.first else { return }
        currentView.beginRename(node)
    }

    @objc func getInfo(_ sender: Any?) {
        guard let device else { return }
        for node in actionNodes.prefix(10) { InfoWindowController.show(node, device: device, storage: storage) }
    }

    @objc func downloadSelection(_ sender: Any?) {
        let items = references(actionNodes)
        guard !items.isEmpty else { return }
        FileOperations.chooseDownloadFolder(window: view.window) { directory in
            FileOperations.download(items, to: directory)
        }
    }

    @objc func upload(_ sender: Any?) {
        guard let location, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "上传")
        panel.message = String(localized: "选择要上传到“\(location.title)”的文件或文件夹")
        let siblings = contents.siblingNames(in: nil)
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated {
                _ = Task { await FileOperations.upload(urls, to: location, knownSiblings: siblings, window: window) }
            }
        }
    }

    @objc func deleteSelection(_ sender: Any?) {
        FileOperations.confirmAndDelete(actionNodes, in: contents, window: view.window)
    }

    /// ⌘C：先下载到本机缓存再放文件 URL（Finder 粘贴不接受文件承诺），见 ClipboardExport
    @objc func copy(_ sender: Any?) {
        let items = references(actionNodes)
        guard !items.isEmpty else { return }
        let total = items.filter { !$0.isFolder }.reduce(UInt64(0)) { $0 + $1.size }
        if total > ClipboardExport.confirmThreshold {
            let alert = NSAlert()
            alert.messageText = String(localized: "拷贝的内容较大（\(Format.bytes(total))）")
            alert.informativeText = String(localized: "要在 Finder 里粘贴，需要先把它们完整下载到本机缓存。更快的做法是直接拖到 Finder，或者用「下载到…」。")
            alert.addButton(withTitle: String(localized: "仍然拷贝"))
            alert.addButton(withTitle: String(localized: "下载到…"))
            alert.addButton(withTitle: String(localized: "取消"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: break
            case .alertSecondButtonReturn: downloadSelection(sender); return
            default: return
            }
        }
        let count = items.count
        flashStatus(String(localized: "正在准备拷贝 \(count) 项…"))
        ClipboardExport.shared.copy(items) { [weak self] failure in
            if let failure {
                self?.flashStatus(nil)
                FileOperations.showMessage(String(localized: "拷贝失败"), detail: failure, window: self?.view.window)
            } else {
                self?.flashStatus(String(localized: "已拷贝 \(count) 项，可以到 Finder 里粘贴"))
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    self?.flashStatus(nil)
                }
            }
        }
    }

    @objc func paste(_ sender: Any?) {
        guard let location else { return }
        let pasteboard = NSPasteboard.general
        let urls = FileOperations.fileURLs(from: pasteboard)
        if urls.isEmpty, !RemoteItemReference.read(from: pasteboard).isEmpty {
            // 拷贝的项目还在下载到缓存；下载完剪贴板里就有文件 URL，粘贴 = 把副本上传（设备内复制）
            FileOperations.showMessage(String(localized: "拷贝的项目还没准备好"),
                                       detail: String(localized: "正在把它们下载到本机，完成后再粘贴即可（进度见传输列表）。"), window: view.window)
            return
        }
        let siblings = contents.siblingNames(in: nil)
        Task { await FileOperations.upload(urls, to: location, knownSiblings: siblings, window: view.window) }
    }

    /// 群组方式（菜单项的 tag 是 FileGrouping.allCases 的下标）
    @objc func groupBy(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag, FileGrouping.allCases.indices.contains(tag) else { return }
        let grouping = FileGrouping.allCases[tag]
        contents.grouping = grouping
        ViewPreferences.set(grouping, for: location?.stored)
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        UserDefaults.standard.set(!FolderContents.showsHiddenFiles, forKey: FolderContents.hiddenFilesKey)
        NotificationCenter.default.post(name: FolderContents.hiddenFilesDidChange, object: nil)
    }

    @objc func showAsIcons(_ sender: Any?) { setViewMode(.icon) }
    @objc func showAsList(_ sender: Any?) { setViewMode(.list) }
    @objc func showAsColumns(_ sender: Any?) { setViewMode(.column) }
    @objc func showAsGallery(_ sender: Any?) { setViewMode(.gallery) }

    // 导航类动作交给窗口控制器
    @objc func goBack(_ sender: Any?) { browser?.goBack(sender) }
    @objc func goForward(_ sender: Any?) { browser?.goForward(sender) }
    @objc func goToEnclosingFolder(_ sender: Any?) { browser?.goToEnclosingFolder(sender) }
    @objc func reload(_ sender: Any?) { browser?.reload(sender) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let nodes = actionNodes
        let searching = contents.searchQuery != nil
        let quirks = device?.quirks
        switch item.action {
        case #selector(openSelection(_:)), #selector(getInfo(_:)), #selector(quickLook(_:)), #selector(downloadSelection(_:)),
             #selector(copy(_:)):
            return !nodes.isEmpty
        case #selector(openSelectionInNewTab(_:)):
            return nodes.contains(where: \.isFolder)
        case #selector(showEnclosingFolder(_:)):
            return searching && nodes.count == 1
        case #selector(newFolder(_:)), #selector(upload(_:)):
            return location?.resolved != nil && isWritable && !searching
        case #selector(renameSelection(_:)):
            return nodes.count == 1 && isWritable && quirks?.canRename == true
        case #selector(deleteSelection(_:)):
            return !nodes.isEmpty && storage?.info.accessCapability != .readOnlyWithoutDeletion && quirks?.canDelete == true
        case #selector(paste(_:)):
            let pasteboard = NSPasteboard.general
            return isWritable && !searching && (pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
                                                || pasteboard.availableType(from: [.pierItem]) != nil)
        case #selector(groupBy(_:)):
            let grouping = FileGrouping.allCases.indices.contains(item.tag) ? FileGrouping.allCases[item.tag] : .none
            item.state = contents.grouping == grouping ? .on : .off
            // 画廊视图和 Finder 一样不分组；设备不给日期时不能按日期分组
            guard location?.resolved != nil, viewMode != .gallery else { return false }
            return grouping != .date || contents.hasDates
        case #selector(toggleHiddenFiles(_:)):
            item.state = FolderContents.showsHiddenFiles ? .on : .off
            return true
        case #selector(showAsIcons(_:)), #selector(showAsList(_:)), #selector(showAsColumns(_:)), #selector(showAsGallery(_:)):
            let modes: [Selector: ViewMode] = [#selector(showAsIcons(_:)): .icon, #selector(showAsList(_:)): .list,
                                               #selector(showAsColumns(_:)): .column, #selector(showAsGallery(_:)): .gallery]
            item.state = modes[item.action!] == viewMode ? .on : .off
            return location?.resolved != nil
        default:
            return browser?.validateMenuItem(item) ?? false
        }
    }
}

// MARK: - Quick Look

extension ContentViewController: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    /// 超过这个大小的文件不自动下载来预览
    private static let previewSizeLimit: UInt64 = 512 << 20

    @objc func quickLook(_ sender: Any?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        let panel = UncheckedBox(panel)
        MainActor.assumeIsolated {
            previewPanel = panel.value
            panel.value?.dataSource = self
            panel.value?.delegate = self
            refreshPreview()
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            previewPanel = nil
            previewNodes = []
        }
    }

    private func refreshPreview() {
        guard let panel = previewPanel else { return }
        let nodes = actionNodes
        guard nodes.map(ObjectIdentifier.init) != previewNodes.map(ObjectIdentifier.init) else { return }
        previewNodes = nodes
        panel.reloadData()
        guard let device else { return }
        for node in nodes where !node.isFolder && node.object.size <= Self.previewSizeLimit
            && LocalCopies.shared.cachedURL(for: node.object, on: device) == nil {
            let object = node.object
            Task { [weak self] in
                _ = try? await LocalCopies.shared.fetch(object, on: device, priority: .interactive)
                guard let self, let panel = self.previewPanel, self.previewNodes.contains(where: { $0.object.handle == object.handle }) else { return }
                panel.refreshCurrentPreviewItem()
            }
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewNodes.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let node = previewNodes[index]
        let url = device.flatMap { LocalCopies.shared.cachedURL(for: node.object, on: $0) }
        return PreviewItem(url: url, title: node.name)
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        guard let item = item as? PreviewItem, let node = previewNodes.first(where: { $0.name == item.title }) else { return .zero }
        return currentView.screenRect(for: node) ?? .zero
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // 面板打开时上下键仍然在列表里移动选择
        guard event.type == .keyDown, [125, 126, 123, 124].contains(event.keyCode) else { return false }
        (currentView.view as? NSScrollView)?.documentView?.keyDown(with: event)
        return true
    }
}

/// Quick Look 的一项。文件还没下载完时 URL 为空，下载完再刷新。
final class PreviewItem: NSObject, QLPreviewItem, @unchecked Sendable {
    let url: URL?
    let title: String

    init(url: URL?, title: String) {
        self.url = url
        self.title = title
    }

    var previewItemURL: URL! { url }
    var previewItemTitle: String! { title }
}

// MARK: - 路径栏拖放

/// 可以把文件拖到路径栏的某一级上
@MainActor
final class PathBarControl: NSPathControl {
    /// 第 index 项对应的位置；nil 表示不能放
    var dropTarget: ((Int) -> BrowserLocation?)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .pierItem])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func target(for sender: NSDraggingInfo) -> BrowserLocation? {
        guard let cell = cell as? NSPathCell else { return nil }
        let point = convert(sender.draggingLocation, from: nil)
        guard let component = cell.pathComponentCell(at: point, withFrame: bounds, in: self),
              let index = cell.pathComponentCells.firstIndex(of: component) else { return nil }
        return dropTarget?(index)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let target = target(for: sender) else { return [] }
        return FileOperations.dropOperation(sender, into: target)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let target = target(for: sender) else { return false }
        return FileOperations.performDrop(sender, into: target, knownSiblings: nil, window: window)
    }
}

// MARK: - 每个文件夹的显示方式

@MainActor
enum ViewPreferences {
    private static let key = "FolderViewModes"
    private static let defaultKey = "DefaultViewMode"
    private static let groupingKey = "FolderGroupings"

    /// 每个文件夹的群组方式；没设置过就不分组
    static func grouping(for location: StoredLocation?) -> FileGrouping {
        guard let location, let raw = (UserDefaults.standard.dictionary(forKey: groupingKey) as? [String: String])?[location.key] else { return .none }
        return FileGrouping(rawValue: raw) ?? .none
    }

    static func set(_ grouping: FileGrouping, for location: StoredLocation?) {
        guard let location else { return }
        var all = (UserDefaults.standard.dictionary(forKey: groupingKey) as? [String: String]) ?? [:]
        all[location.key] = grouping == .none ? nil : grouping.rawValue
        UserDefaults.standard.set(all, forKey: groupingKey)
    }

    static func mode(for location: StoredLocation?) -> ContentViewController.ViewMode {
        let defaults = UserDefaults.standard
        if let location, let raw = (defaults.dictionary(forKey: key) as? [String: String])?[location.key],
           let mode = ContentViewController.ViewMode(rawValue: raw) { return mode }
        return defaults.string(forKey: defaultKey).flatMap(ContentViewController.ViewMode.init) ?? .list
    }

    static func set(_ mode: ContentViewController.ViewMode, for location: StoredLocation?) {
        let defaults = UserDefaults.standard
        defaults.set(mode.rawValue, forKey: defaultKey)
        guard let location else { return }
        var all = (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
        all[location.key] = mode.rawValue
        if all.count > 500 { all = Dictionary(uniqueKeysWithValues: all.shuffled().prefix(400).map { ($0.key, $0.value) }) }
        defaults.set(all, forKey: key)
    }
}
