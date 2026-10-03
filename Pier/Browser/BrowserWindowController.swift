import AppKit
import PierKit

/// 一个浏览窗口（或一个 tab）。持有当前位置和前进/后退历史，负责工具栏与导航类动作。
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    private(set) var location: BrowserLocation?
    private var backStack: [BrowserLocation] = []
    private var forwardStack: [BrowserLocation] = []

    var onClose: (() -> Void)?

    private let splitController = BrowserSplitViewController()
    private var searchItem: NSSearchToolbarItem?

    init(location: BrowserLocation?) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 560, height: 320)
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "work.xiaolin.Pier.browser"
        window.isRestorable = false   // 状态恢复留到后续版本
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

        NotificationCenter.default.addObserver(self, selector: #selector(devicesDidChange(_:)),
                                               name: DeviceManager.devicesDidChange, object: nil)
        navigate(to: location ?? defaultLocation(), recordHistory: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: 导航

    func navigate(to newLocation: BrowserLocation?, recordHistory: Bool = true) {
        guard newLocation != location else { return }
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
        window?.toolbar?.validateVisibleItems()
    }

    /// 没有指定位置时，打开第一台就绪设备的第一个存储
    private func defaultLocation() -> BrowserLocation? {
        for device in DeviceManager.shared.devices {
            if case .ready = device.state, let s = device.storages.first {
                return BrowserLocation(deviceID: device.id, storageID: s.id)
            }
        }
        return nil
    }

    @objc private func devicesDidChange(_ note: Notification) {
        if let location, location.resolved == nil {
            // 当前设备已断开：历史里属于这台设备的位置也一并失效
            backStack.removeAll { $0.deviceID == location.deviceID }
            forwardStack.removeAll { $0.deviceID == location.deviceID }
            self.location = nil
            locationDidChange()
        }
        if location == nil, let fallback = defaultLocation() {
            navigate(to: fallback, recordHistory: false)
        }
        // 存储名等可能变化
        window?.title = location?.title ?? "Pier"
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        onClose?()
    }

    // MARK: tab

    override func newWindowForTab(_ sender: Any?) {
        guard let window else { return }
        (NSApp.delegate as? AppDelegate)?.openBrowser(location: location, tabbedWith: window)
    }
}

// MARK: - 导航动作（响应链）

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
        guard let searchItem else { return }
        searchItem.beginSearchInteraction()
    }

    @objc func ejectDevice(_ sender: Any?) {
        guard let device = location?.resolved?.device else { return }
        DeviceManager.shared.eject(device)
    }

    @objc func togglePathBar(_ sender: Any?) { splitController.content.togglePathBar() }
    @objc func toggleStatusBar(_ sender: Any?) { splitController.content.toggleStatusBar() }
    @objc func showAsList(_ sender: Any?) {}
    @objc func showAsIcons(_ sender: Any?) { NSSound.beep() }   // 图标视图尚未实现

    // 以下由文件列表实现；落到窗口控制器说明没有可用的选择
    @objc func newFolder(_ sender: Any?) {}
    @objc func openSelection(_ sender: Any?) {}
    @objc func openSelectionInNewTab(_ sender: Any?) {}
    @objc func getInfo(_ sender: Any?) {}
    @objc func downloadSelection(_ sender: Any?) {}
    @objc func upload(_ sender: Any?) {}
    @objc func deleteSelection(_ sender: Any?) {}

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(togglePathBar(_:)):
            item.title = splitController.content.isPathBarVisible ? String(localized: "隐藏路径栏") : String(localized: "显示路径栏")
            return true
        case #selector(toggleStatusBar(_:)):
            item.title = splitController.content.isStatusBarVisible ? String(localized: "隐藏状态栏") : String(localized: "显示状态栏")
            return true
        case #selector(showAsList(_:)):
            item.state = .on
            return true
        case #selector(showAsIcons(_:)):
            item.state = .off
            return false
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
        case #selector(reload(_:)), #selector(ejectDevice(_:)): location?.resolved != nil
        case #selector(focusSearch(_:)): true
        case #selector(newWindowForTab(_:)): true
        default: false
        }
    }
}

// MARK: - 工具栏

private extension NSToolbarItem.Identifier {
    static let back = Self("back")
    static let forward = Self("forward")
    static let viewMode = Self("viewMode")
    static let actions = Self("actions")
    static let transfers = Self("transfers")
    static let search = Self("search")
}

extension BrowserWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .back, .forward, .flexibleSpace, .viewMode, .actions, .transfers, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .back, .forward, .viewMode, .actions, .transfers, .search, .flexibleSpace, .space]
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
            let group = NSToolbarItemGroup(itemIdentifier: id,
                                           images: [symbol("square.grid.2x2"), symbol("list.bullet")],
                                           selectionMode: .selectOne,
                                           labels: [String(localized: "图标"), String(localized: "列表")],
                                           target: self, action: #selector(viewModeChanged(_:)))
            group.label = String(localized: "显示")
            group.selectedIndex = 1
            group.subitems.first?.isEnabled = false   // 图标视图尚未实现
            return group
        case .actions:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = symbol("ellipsis.circle")
            item.label = String(localized: "操作")
            item.toolTip = item.label
            item.menu = actionsMenu()
            return item
        case .transfers:
            let item = button(id, symbol: "arrow.down.circle", label: String(localized: "传输"), action: #selector(showTransfers(_:)))
            item.target = self
            return item
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.label = String(localized: "搜索")
            item.searchField.placeholderString = String(localized: "搜索当前文件夹")
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            item.searchField.sendsSearchStringImmediately = true
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
        item.image = symbol(name)
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
        m.addItem(.separator())
        m.addItem(withTitle: String(localized: "显示简介"), action: #selector(BrowserActions.getInfo(_:)), keyEquivalent: "")
        m.addItem(withTitle: String(localized: "下载到…"), action: #selector(BrowserActions.downloadSelection(_:)), keyEquivalent: "")
        m.addItem(withTitle: String(localized: "上传…"), action: #selector(BrowserActions.upload(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: String(localized: "刷新"), action: #selector(BrowserActions.reload(_:)), keyEquivalent: "")
        return m
    }

    @objc private func viewModeChanged(_ sender: NSToolbarItemGroup) {
        sender.selectedIndex = 1
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        splitController.content.fileList.filterText = sender.stringValue
    }

    @objc private func showTransfers(_ sender: Any?) {
        // 传输队列在下一阶段实现；这里先放一个占位 popover
        guard let view = window?.toolbar?.items.first(where: { $0.itemIdentifier == .transfers })?.view
                ?? window?.contentView else { return }
        let label = NSTextField(labelWithString: String(localized: "没有正在进行的传输"))
        label.textColor = .secondaryLabelColor
        let vc = NSViewController()
        vc.view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 80))
        label.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: vc.view.centerXAnchor),
                                     label.centerYAnchor.constraint(equalTo: vc.view.centerYAnchor)])
        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}
