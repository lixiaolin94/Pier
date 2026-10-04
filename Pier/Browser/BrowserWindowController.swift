import AppKit
import PierKit

/// 一个浏览窗口（或一个 tab）。持有当前位置和前进/后退历史，负责工具栏与导航类动作。
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    private(set) var location: BrowserLocation?
    private var backStack: [BrowserLocation] = []
    private var forwardStack: [BrowserLocation] = []
    /// 窗口恢复时要回到的位置；设备连上之前先记着
    private var pendingRestore: StoredLocation?

    var onClose: (() -> Void)?

    private let splitController = BrowserSplitViewController()
    private var searchItem: NSSearchToolbarItem?
    private var viewModeItem: NSToolbarItemGroup?
    private var transfersItem: NSToolbarItem?
    private var transfersPopover: NSPopover?

    static let restorationIdentifier = NSUserInterfaceItemIdentifier("work.xiaolin.Pier.browser")

    var content: ContentViewController { splitController.content }

    init(location: BrowserLocation?, restoring stored: StoredLocation? = nil) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 560, height: 320)
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "work.xiaolin.Pier.browser"
        window.identifier = Self.restorationIdentifier
        window.isRestorable = true
        window.restorationClass = BrowserWindowRestoration.self
        super.init(window: window)

        window.delegate = self
        window.contentViewController = splitController
        splitController.browser = self
        window.setContentSize(NSSize(width: 1000, height: 620))
        if !window.setFrameUsingName("PierBrowser") { window.center() }
        window.setFrameAutosaveName("PierBrowser")

        let toolbar = NSToolbar(identifier: "work.xiaolin.Pier.browser")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(devicesDidChange(_:)), name: DeviceManager.devicesDidChange, object: nil)
        center.addObserver(self, selector: #selector(transfersDidUpdate(_:)), name: TransferQueue.didChange, object: nil)
        center.addObserver(self, selector: #selector(transfersDidUpdate(_:)), name: TransferQueue.progressDidUpdate, object: nil)

        pendingRestore = stored
        if let stored, location == nil {
            content.setPlaceholder(String(localized: "等待“\(stored.deviceName)”连接…"))
            navigate(to: nil, recordHistory: false)
            tryRestore()
        } else {
            navigate(to: location ?? defaultLocation(), recordHistory: false)
        }
        updateTransfersItem()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: 导航

    func navigate(to newLocation: BrowserLocation?, recordHistory: Bool = true) {
        if newLocation != nil { pendingRestore = nil }
        guard newLocation != location || newLocation == nil else { return }
        if recordHistory, let location {
            backStack.append(location)
            forwardStack.removeAll()
        }
        location = newLocation
        locationDidChange()
    }

    /// 在新 tab 中打开某个位置
    func openInNewTab(_ location: BrowserLocation) {
        guard let window else { return }
        (NSApp.delegate as? AppDelegate)?.openBrowser(location: location, tabbedWith: window)
    }

    private func locationDidChange() {
        window?.title = location?.title ?? "Pier"
        searchItem?.searchField.stringValue = ""
        splitController.show(location)
        viewModeDidChange()
        window?.toolbar?.validateVisibleItems()
        window?.invalidateRestorableState()
    }

    /// 没有指定位置时，打开第一台就绪设备的第一个存储
    private func defaultLocation() -> BrowserLocation? {
        for device in DeviceManager.shared.devices {
            if device.isReady, let s = device.storages.first {
                return BrowserLocation(deviceID: device.id, storageID: s.id)
            }
        }
        return nil
    }

    private func tryRestore() {
        guard let stored = pendingRestore, DeviceManager.shared.readyDevice(persistentID: stored.deviceID) != nil else { return }
        Task { [weak self] in
            // 文件夹可能已经不在了：退回到存储根目录
            var resolved = await stored.resolve()
            if resolved == nil {
                var root = stored
                root.path = []
                resolved = await root.resolve()
            }
            guard let self, self.pendingRestore == stored, let resolved else { return }
            self.content.setPlaceholder(nil)
            self.navigate(to: resolved, recordHistory: false)
        }
    }

    @objc private func devicesDidChange(_ note: Notification) {
        if let location, location.resolved == nil {
            // 当前设备已断开：历史里属于这台设备的位置也一并失效
            backStack.removeAll { $0.deviceID == location.deviceID }
            forwardStack.removeAll { $0.deviceID == location.deviceID }
            self.location = nil
            locationDidChange()
        }
        if pendingRestore != nil {
            tryRestore()
        } else if location == nil, let fallback = defaultLocation() {
            navigate(to: fallback, recordHistory: false)
        }
        // 存储名等可能变化
        window?.title = location?.title ?? "Pier"
    }

    func viewModeDidChange() {
        viewModeItem?.selectedIndex = ContentViewController.ViewMode.allCases.firstIndex(of: content.viewMode) ?? 1
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        onClose?()
    }

    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        let stored = location?.stored ?? pendingRestore
        if let data = try? JSONEncoder().encode(stored) { state.encode(data, forKey: "location") }
    }

    // MARK: tab

    override func newWindowForTab(_ sender: Any?) {
        guard let window else { return }
        (NSApp.delegate as? AppDelegate)?.openBrowser(location: location, tabbedWith: window)
    }
}

/// 窗口恢复：重启后回到上次的位置和 tab（tab 分组由 AppKit 自动恢复）
final class BrowserWindowRestoration: NSObject, NSWindowRestoration {
    static func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder,
                              completionHandler: @escaping (NSWindow?, Error?) -> Void) {
        let data = state.decodeObject(of: NSData.self, forKey: "location") as Data?
        let stored = data.flatMap { try? JSONDecoder().decode(StoredLocation?.self, from: $0) } ?? nil
        MainActor.assumeIsolated {
            let controller = (NSApp.delegate as? AppDelegate)?.makeBrowser(location: nil, restoring: stored)
            completionHandler(controller?.window, nil)
        }
    }
}

// MARK: - 导航与文件动作（响应链）

extension BrowserWindowController: BrowserActions, NSMenuItemValidation, NSToolbarItemValidation {
    @objc func goBack(_ sender: Any?) {
        guard let previous = backStack.popLast() else { return }
        if let location { forwardStack.append(location) }
        location = previous
        locationDidChange()
    }

    @objc func goForward(_ sender: Any?) {
        guard let next = forwardStack.popLast() else { return }
        if let location { backStack.append(location) }
        location = next
        locationDidChange()
    }

    @objc func goToEnclosingFolder(_ sender: Any?) {
        guard let parent = location?.parent else { return }
        navigate(to: parent)
    }

    @objc func reload(_ sender: Any?) {
        splitController.show(location, forceReload: true)
    }

    @objc func focusSearch(_ sender: Any?) {
        searchItem?.beginSearchInteraction()
    }

    @objc func ejectDevice(_ sender: Any?) {
        guard let device = location?.resolved?.device else { return }
        DeviceManager.shared.eject(device)
    }

    @objc func reconnectDevice(_ sender: Any?) {
        guard let device = location?.resolved?.device else { return }
        DeviceManager.shared.reconnect(device)
    }

    @objc func togglePathBar(_ sender: Any?) { content.togglePathBar() }
    @objc func toggleStatusBar(_ sender: Any?) { content.toggleStatusBar() }

    // 焦点在侧边栏时，文件动作也要能用：转给内容区
    @objc func toggleHiddenFiles(_ sender: Any?) { content.toggleHiddenFiles(sender) }
    @objc func showAsIcons(_ sender: Any?) { content.showAsIcons(sender) }
    @objc func showAsList(_ sender: Any?) { content.showAsList(sender) }
    @objc func showAsColumns(_ sender: Any?) { content.showAsColumns(sender) }
    @objc func showAsGallery(_ sender: Any?) { content.showAsGallery(sender) }
    @objc func newFolder(_ sender: Any?) { content.newFolder(sender) }
    @objc func openSelection(_ sender: Any?) { content.openSelection(sender) }
    @objc func openSelectionInNewTab(_ sender: Any?) { content.openSelectionInNewTab(sender) }
    @objc func getInfo(_ sender: Any?) { content.getInfo(sender) }
    @objc func downloadSelection(_ sender: Any?) { content.downloadSelection(sender) }
    @objc func upload(_ sender: Any?) { content.upload(sender) }
    @objc func deleteSelection(_ sender: Any?) { content.deleteSelection(sender) }
    @objc func renameSelection(_ sender: Any?) { content.renameSelection(sender) }
    @objc func quickLook(_ sender: Any?) { content.quickLook(sender) }
    @objc func showEnclosingFolder(_ sender: Any?) { content.showEnclosingFolder(sender) }

    @objc func showTransfers(_ sender: Any?) {
        if let popover = transfersPopover, popover.isShown {
            popover.performClose(sender)
            return
        }
        guard let window else { return }
        if !window.isVisible || window.isMiniaturized { window.makeKeyAndOrderFront(nil) }
        let popover = NSPopover()
        popover.contentViewController = TransfersViewController()
        popover.behavior = .transient
        transfersPopover = popover
        if #available(macOS 14.0, *), let item = transfersItem, window.toolbar?.items.contains(item) == true, window.toolbar?.isVisible == true {
            popover.show(relativeTo: item)
        } else if let contentView = window.contentView {
            // 工具栏里没有传输按钮时，从窗口右上角弹出
            let rect = NSRect(x: contentView.bounds.maxX - 60, y: contentView.bounds.maxY - 60, width: 40, height: 1)
            popover.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(togglePathBar(_:)):
            item.title = content.isPathBarVisible ? String(localized: "隐藏路径栏") : String(localized: "显示路径栏")
            return true
        case #selector(toggleStatusBar(_:)):
            item.title = content.isStatusBarVisible ? String(localized: "隐藏状态栏") : String(localized: "显示状态栏")
            return true
        case #selector(toggleHiddenFiles(_:)), #selector(showAsIcons(_:)), #selector(showAsList(_:)), #selector(showAsColumns(_:)), #selector(showAsGallery(_:)), #selector(newFolder(_:)), #selector(openSelection(_:)),
             #selector(openSelectionInNewTab(_:)), #selector(getInfo(_:)), #selector(downloadSelection(_:)), #selector(upload(_:)),
             #selector(deleteSelection(_:)), #selector(renameSelection(_:)), #selector(quickLook(_:)),
             #selector(showEnclosingFolder(_:)):
            return content.validateMenuItem(item)
        default:
            return validate(item.action)
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { validate(item.action) }

    private func validate(_ action: Selector?) -> Bool {
        switch action {
        case #selector(goBack(_:)): !backStack.isEmpty
        case #selector(goForward(_:)): !forwardStack.isEmpty
        case #selector(goToEnclosingFolder(_:)): location?.parent != nil
        case #selector(reload(_:)), #selector(ejectDevice(_:)), #selector(reconnectDevice(_:)): location?.resolved != nil
        case #selector(focusSearch(_:)), #selector(newWindowForTab(_:)), #selector(showTransfers(_:)): true
        case #selector(viewModeChanged(_:)): location?.resolved != nil
        default: false
        }
    }
}

// MARK: - 工具栏

private extension NSToolbarItem.Identifier {
    static let back = Self("back")
    static let forward = Self("forward")
    static let viewMode = Self("viewMode")
    static let reload = Self("reload")
    static let actions = Self("actions")
    static let transfers = Self("transfers")
    static let search = Self("search")
}

extension BrowserWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .back, .forward, .flexibleSpace, .viewMode, .reload, .actions, .transfers, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .back, .forward, .viewMode, .reload, .actions, .transfers, .search, .flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .sidebarTrackingSeparator:
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: splitController.splitView, dividerIndex: 0)
        case .back:
            return button(id, symbol: "chevron.left", label: String(localized: "返回"), action: #selector(goBack(_:)), navigational: true)
        case .forward:
            return button(id, symbol: "chevron.right", label: String(localized: "前进"), action: #selector(goForward(_:)), navigational: true)
        case .viewMode:
            // 和 Finder 相同的四个符号与顺序
            let labels = [String(localized: "图标"), String(localized: "列表"), String(localized: "分栏"), String(localized: "画廊")]
            let symbols = ["square.grid.2x2", "list.bullet", "rectangle.split.3x1", "squares.below.rectangle"]
            let group = NSToolbarItemGroup(itemIdentifier: id,
                                           images: zip(symbols, labels).map { NSImage(systemSymbolName: $0, accessibilityDescription: $1) ?? NSImage() },
                                           selectionMode: .selectOne,
                                           labels: labels,
                                           target: self, action: #selector(viewModeChanged(_:)))
            group.label = String(localized: "显示")
            group.selectedIndex = ContentViewController.ViewMode.allCases.firstIndex(of: content.viewMode) ?? 1
            viewModeItem = group
            return group
        case .reload:
            return button(id, symbol: "arrow.clockwise", label: String(localized: "刷新"), action: #selector(reload(_:)))
        case .actions:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = symbol("ellipsis.circle")
            item.label = String(localized: "操作")
            item.toolTip = item.label
            item.menu = actionsMenu()
            item.showsIndicator = false   // Finder 的「操作」按钮没有下拉箭头
            return item
        case .transfers:
            let item = button(id, symbol: "arrow.down.circle", label: String(localized: "传输"), action: #selector(showTransfers(_:)))
            item.target = self
            transfersItem = item
            updateTransfersItem()
            return item
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.label = String(localized: "搜索")
            item.searchField.toolTip = String(localized: "输入时过滤当前文件夹，按回车搜索所有子文件夹")
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.delegate = self
            searchItem = item
            return item
        default:
            return nil
        }
    }

    private func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
    }

    private func button(_ id: NSToolbarItem.Identifier, symbol name: String, label: String, action: Selector, navigational: Bool = false) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: name, accessibilityDescription: label)
        item.label = label
        item.toolTip = label
        item.action = action
        item.isBordered = true
        item.autovalidates = true
        if navigational { item.isNavigational = true }
        return item
    }

    private func actionsMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: String(localized: "新建文件夹"), action: #selector(BrowserActions.newFolder(_:)), keyEquivalent: "")
        m.addItem(withTitle: String(localized: "上传…"), action: #selector(BrowserActions.upload(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: String(localized: "下载到…"), action: #selector(BrowserActions.downloadSelection(_:)), keyEquivalent: "")
        m.addItem(withTitle: String(localized: "快速查看"), action: #selector(BrowserActions.quickLook(_:)), keyEquivalent: "")
        m.addItem(withTitle: String(localized: "显示简介"), action: #selector(BrowserActions.getInfo(_:)), keyEquivalent: "")
        m.addItem(withTitle: String(localized: "重新命名"), action: #selector(BrowserActions.renameSelection(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: String(localized: "删除"), action: #selector(BrowserActions.deleteSelection(_:)), keyEquivalent: "")
        return m
    }

    @objc private func viewModeChanged(_ sender: NSToolbarItemGroup) {
        let modes = ContentViewController.ViewMode.allCases
        guard modes.indices.contains(sender.selectedIndex) else { return }
        content.setViewMode(modes[sender.selectedIndex])
    }

    /// 输入过程中只过滤当前文件夹
    @objc private func searchChanged(_ sender: NSSearchField) {
        content.search(sender.stringValue, recursive: false)
    }

    @objc private func transfersDidUpdate(_ note: Notification) { updateTransfersItem() }

    private func updateTransfersItem() {
        guard let item = transfersItem else { return }
        let queue = Services.transfers
        let (fraction, count) = queue.overallProgress
        let failed = queue.transfers.contains { $0.state.isFailed }
        let running = queue.transfers.contains { $0.state.isRunning }
        item.image = TransferToolbarIcon.image(fraction: running ? fraction : nil, failed: failed)
        item.toolTip = count > 0 ? String(localized: "传输：\(count) 个任务未完成") : String(localized: "传输")
    }
}

// MARK: - 搜索框：回车 = 递归搜索整个子树

extension BrowserWindowController: NSSearchFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === searchItem?.searchField, selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        content.search(control.stringValue, recursive: true)
        return true
    }
}
