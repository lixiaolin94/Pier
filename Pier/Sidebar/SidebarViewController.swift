import AppKit
import PierKit

/// 侧边栏条目。NSOutlineView 需要引用类型，并且靠对象身份追踪展开状态。
@MainActor
final class SidebarItem: NSObject {
    enum Kind {
        case group(String)
        case device(MTPDevice)
        case storage(MTPDevice, MTPStorage)
        case favorite(StoredLocation)
        case placeholder(String)
    }

    let kind: Kind
    var children: [SidebarItem] = []

    init(_ kind: Kind, children: [SidebarItem] = []) {
        self.kind = kind
        self.children = children
    }

    var storageLocation: BrowserLocation? {
        if case let .storage(device, storage) = kind { return BrowserLocation(deviceID: device.id, storageID: storage.id) }
        return nil
    }

    /// 分组标识（"favorites" 表示收藏分组）
    var tag: String?
}

@MainActor
final class SidebarViewController: NSViewController {
    weak var browser: BrowserWindowController?

    private let outlineView = NSOutlineView()
    private var groups: [SidebarItem] = []
    /// 程序化设置选中时，不要反过来触发导航
    private var suppressSelectionNavigation = false
    private var lastLocation: BrowserLocation?
    /// 收藏解析出的当前位置（设备就绪时按名字找回句柄）
    private var resolvedFavorites: [StoredLocation: BrowserLocation] = [:]
    private var resolveTask: Task<Void, Never>?

    override func loadView() {
        let column = NSTableColumn(identifier: .init("main"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.floatsGroupRows = false
        outlineView.autosaveExpandedItems = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked(_:))
        outlineView.menu = NSMenu()
        outlineView.menu?.delegate = self
        outlineView.registerForDraggedTypes([.fileURL, .pierItem, .favoriteIndex])
        outlineView.draggingDestinationFeedbackStyle = .sourceList
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(dataDidChange(_:)), name: DeviceManager.devicesDidChange, object: nil)
        center.addObserver(self, selector: #selector(dataDidChange(_:)), name: Favorites.didChange, object: nil)
        rebuild()
    }

    // MARK: 数据

    @objc private func dataDidChange(_ note: Notification) { rebuild() }

    private func rebuild() {
        var deviceItems: [SidebarItem] = []
        for device in DeviceManager.shared.devices {
            let storages: [SidebarItem]
            switch device.state {
            case .connecting: storages = [SidebarItem(.placeholder(String(localized: "正在连接…")))]
            case .failed: storages = [SidebarItem(.placeholder(String(localized: "连接失败")))]
            case .ready: storages = device.storages.map { SidebarItem(.storage(device, $0)) }
            }
            deviceItems.append(SidebarItem(.device(device), children: storages))
        }
        if deviceItems.isEmpty {
            deviceItems = [SidebarItem(.placeholder(String(localized: "未连接设备")))]
        }
        var favoriteItems = Favorites.shared.items.map { SidebarItem(.favorite($0)) }
        if favoriteItems.isEmpty { favoriteItems = [SidebarItem(.placeholder(String(localized: "把文件夹拖到这里")))] }
        let favorites = SidebarItem(.group(String(localized: "收藏")), children: favoriteItems)
        favorites.tag = "favorites"
        groups = [favorites, SidebarItem(.group(String(localized: "设备")), children: deviceItems)]

        outlineView.reloadData()
        for group in groups {
            outlineView.expandItem(group)
            group.children.forEach { outlineView.expandItem($0) }
        }
        select(lastLocation)
        resolveFavorites()
    }

    /// 后台把收藏解析成当前会话的位置，点击和拖放时就不用等
    private func resolveFavorites() {
        resolveTask?.cancel()
        let favorites = Favorites.shared.items
        resolveTask = Task { [weak self] in
            var resolved: [StoredLocation: BrowserLocation] = [:]
            for favorite in favorites {
                if let location = await favorite.resolve() { resolved[favorite] = location }
                if Task.isCancelled { return }
            }
            guard let self else { return }
            self.resolvedFavorites = resolved
            self.outlineView.reloadData()
            self.select(self.lastLocation)
        }
    }

    /// 根据当前浏览位置高亮对应的收藏或存储（不触发导航）
    func select(_ location: BrowserLocation?) {
        lastLocation = location
        suppressSelectionNavigation = true
        defer { suppressSelectionNavigation = false }
        guard let location else {
            outlineView.deselectAll(nil)
            return
        }
        var storageRow: Int?
        for row in 0..<outlineView.numberOfRows {
            guard let item = outlineView.item(atRow: row) as? SidebarItem else { continue }
            if case let .favorite(f) = item.kind, resolvedFavorites[f] == location {
                outlineView.selectRowIndexes([row], byExtendingSelection: false)
                return
            }
            if let l = item.storageLocation, l.deviceID == location.deviceID, l.storageID == location.storageID, location.path.isEmpty {
                storageRow = row
            }
        }
        if let storageRow { outlineView.selectRowIndexes([storageRow], byExtendingSelection: false) } else { outlineView.deselectAll(nil) }
    }

    private func location(for item: SidebarItem) -> BrowserLocation? {
        switch item.kind {
        case .storage: return item.storageLocation
        case let .favorite(f): return resolvedFavorites[f]
        default: return nil
        }
    }

    /// 收藏还没解析好时，现在解析再打开
    private func openFavorite(_ favorite: StoredLocation, inNewTab: Bool) {
        if let l = resolvedFavorites[favorite] {
            inNewTab ? browser?.openInNewTab(l) : browser?.navigate(to: l)
            return
        }
        Task { [weak self] in
            guard let l = await favorite.resolve() else {
                NSSound.beep()
                return
            }
            self?.resolvedFavorites[favorite] = l
            inNewTab ? self?.browser?.openInNewTab(l) : self?.browser?.navigate(to: l)
        }
    }

    // MARK: 交互

    @objc private func rowClicked(_ sender: NSOutlineView) {
        // ⌘单击：在新 tab 中打开，当前 tab 保持不动
        guard NSApp.currentEvent?.modifierFlags.contains(.command) == true,
              let item = outlineView.item(atRow: outlineView.clickedRow) as? SidebarItem else { return }
        select(lastLocation)
        if case let .favorite(f) = item.kind {
            openFavorite(f, inNewTab: true)
        } else if let location = item.storageLocation {
            browser?.openInNewTab(location)
        }
    }

    @objc private func ejectClicked(_ sender: NSButton) {
        let row = outlineView.row(for: sender)
        guard let item = outlineView.item(atRow: row) as? SidebarItem, case let .device(device) = item.kind else { return }
        DeviceManager.shared.eject(device)
    }

    @objc private func openInNewTab(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? SidebarItem else { return }
        if case let .favorite(f) = item.kind { openFavorite(f, inNewTab: true) } else if let l = item.storageLocation { browser?.openInNewTab(l) }
    }

    @objc private func openAllStoragesInTabs(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? SidebarItem else { return }
        let locations = item.children.compactMap(\.storageLocation)
        guard let first = locations.first else { return }
        browser?.navigate(to: first)
        locations.dropFirst().forEach { browser?.openInNewTab($0) }
    }

    @objc private func ejectFromMenu(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? SidebarItem, case let .device(device) = item.kind else { return }
        DeviceManager.shared.eject(device)
    }

    @objc private func reconnectFromMenu(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? SidebarItem, case let .device(device) = item.kind else { return }
        DeviceManager.shared.reconnect(device)
    }

    @objc private func removeFavorite(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? SidebarItem, case let .favorite(f) = item.kind else { return }
        Favorites.shared.remove(f)
    }
}

// MARK: - NSOutlineViewDataSource / Delegate

extension SidebarViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? SidebarItem else { return groups.count }
        return item.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? SidebarItem else { return groups[index] }
        return item.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? SidebarItem)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        if case .group = (item as? SidebarItem)?.kind { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let item = item as? SidebarItem else { return false }
        switch item.kind {
        case .storage, .favorite: return true
        default: return false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        if case .device = (item as? SidebarItem)?.kind { return true }
        return false
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionNavigation, let item = outlineView.item(atRow: outlineView.selectedRow) as? SidebarItem else { return }
        if case let .favorite(f) = item.kind {
            openFavorite(f, inNewTab: false)
        } else if let location = item.storageLocation {
            lastLocation = location
            browser?.navigate(to: location)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? SidebarItem else { return nil }
        switch item.kind {
        case let .group(title):
            let cell = reuse(.init("header")) { SidebarCell(header: true) }
            cell.textField?.stringValue = title
            return cell
        case let .device(device):
            let cell = reuse(.init("device")) { SidebarCell(header: false, withEject: true) }
            cell.textField?.stringValue = device.name
            cell.textField?.textColor = .labelColor
            cell.imageView?.image = NSImage(systemSymbolName: Self.symbol(for: device), accessibilityDescription: nil)
            cell.ejectButton?.target = self
            cell.ejectButton?.action = #selector(ejectClicked(_:))
            if case .connecting = device.state { cell.ejectButton?.isHidden = true } else { cell.ejectButton?.isHidden = false }
            return cell
        case let .storage(device, storage):
            let cell = reuse(.init("storage")) { SidebarCell(header: false) }
            cell.textField?.stringValue = storage.displayName
            cell.textField?.textColor = .labelColor
            let symbol = storage.displayName.localizedCaseInsensitiveContains("SD") ? "sdcard" : "internaldrive"
            cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            let free = Format.bytes(storage.info.freeSpace)
            cell.toolTip = device.quirks?.freeSpaceIsCached == true
                ? String(localized: "约 \(free) 可用（连接时的数据），共 \(Format.bytes(storage.info.maxCapacity))")
                : String(localized: "\(free) 可用，共 \(Format.bytes(storage.info.maxCapacity))")
            return cell
        case let .favorite(f):
            let cell = reuse(.init("favorite")) { SidebarCell(header: false) }
            cell.textField?.stringValue = f.name
            let available = DeviceManager.shared.readyDevice(persistentID: f.deviceID) != nil
            cell.textField?.textColor = available ? .labelColor : .tertiaryLabelColor
            cell.imageView?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            cell.toolTip = ([f.deviceName, f.storageName] + f.path).joined(separator: " ▸ ")
            return cell
        case let .placeholder(text):
            let cell = reuse(.init("placeholder")) { SidebarCell(header: false) }
            cell.textField?.stringValue = text
            cell.textField?.textColor = .secondaryLabelColor
            cell.imageView?.image = nil
            return cell
        }
    }

    private func reuse(_ id: NSUserInterfaceItemIdentifier, make: () -> SidebarCell) -> SidebarCell {
        if let cell = outlineView.makeView(withIdentifier: id, owner: self) as? SidebarCell { return cell }
        let cell = make()
        cell.identifier = id
        return cell
    }

    private static func symbol(for device: MTPDevice) -> String {
        let manufacturer = device.deviceInfo?.manufacturer ?? ""
        if manufacturer.localizedCaseInsensitiveContains("Nintendo") { return "gamecontroller" }
        return "candybarphone"
    }

    // MARK: 拖放

    /// 收藏可以拖动排序
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let item = item as? SidebarItem, case let .favorite(f) = item.kind,
              let index = Favorites.shared.items.firstIndex(of: f) else { return nil }
        let pb = NSPasteboardItem()
        pb.setString(String(index), forType: .favoriteIndex)
        return pb
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let item = item as? SidebarItem else { return [] }
        let pasteboard = info.draggingPasteboard
        // 收藏排序
        if pasteboard.string(forType: .favoriteIndex) != nil {
            return item.tag == "favorites" && index != NSOutlineViewDropOnItemIndex ? .move : []
        }
        // 把文件夹拖进收藏分组 = 添加收藏
        if item.tag == "favorites" {
            let folders = RemoteItemReference.read(from: pasteboard).filter(\.isFolder)
            guard !folders.isEmpty else { return [] }
            outlineView.setDropItem(item, dropChildIndex: index == NSOutlineViewDropOnItemIndex ? Favorites.shared.items.count : index)
            return .link
        }
        // 拖到存储或收藏上 = 上传 / 移动到那里
        guard index == NSOutlineViewDropOnItemIndex, let target = location(for: item) else { return [] }
        return FileOperations.dropOperation(info, into: target)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let item = item as? SidebarItem else { return false }
        let pasteboard = info.draggingPasteboard
        if let source = pasteboard.string(forType: .favoriteIndex).flatMap(Int.init) {
            Favorites.shared.move(from: source, to: index)
            return true
        }
        if item.tag == "favorites" {
            for folder in RemoteItemReference.read(from: pasteboard) where folder.isFolder {
                guard let device = DeviceManager.shared.readyDevice(persistentID: folder.persistentID),
                      let storage = device.storages.first(where: { $0.id == folder.storageID }) else { continue }
                Favorites.shared.add(StoredLocation(deviceID: folder.persistentID, deviceName: folder.deviceName, storageID: folder.storageID,
                                                    storageName: storage.displayName, path: folder.folderPath.map(\.name) + [folder.name]))
            }
            return true
        }
        guard let target = location(for: item) else { return false }
        return FileOperations.performDrop(info, into: target, knownSiblings: nil, window: view.window)
    }
}

extension NSPasteboard.PasteboardType {
    static let favoriteIndex = NSPasteboard.PasteboardType("work.xiaolin.Pier.favorite-index")
}

// MARK: - 右键菜单

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let item = outlineView.item(atRow: outlineView.clickedRow) as? SidebarItem else { return }
        func add(_ title: String, _ action: Selector) {
            let menuItem = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            menuItem.representedObject = item
            menuItem.target = self
        }
        switch item.kind {
        case .storage:
            add(String(localized: "在新标签页中打开"), #selector(openInNewTab(_:)))
        case .favorite:
            add(String(localized: "在新标签页中打开"), #selector(openInNewTab(_:)))
            menu.addItem(.separator())
            add(String(localized: "从边栏中移除"), #selector(removeFavorite(_:)))
        case .device:
            add(String(localized: "在标签页中打开所有存储"), #selector(openAllStoragesInTabs(_:)))
            menu.addItem(.separator())
            add(String(localized: "重新连接"), #selector(reconnectFromMenu(_:)))
            add(String(localized: "推出"), #selector(ejectFromMenu(_:)))
        default:
            break
        }
    }
}

/// 侧边栏单元格：图标 + 文字（+ 可选的推出按钮）
@MainActor
final class SidebarCell: NSTableCellView {
    private(set) var ejectButton: NSButton?

    init(header: Bool, withEject: Bool = false) {
        super.init(frame: .zero)
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        textField = text

        if header {
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            return
        }

        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        image.symbolConfiguration = .init(scale: .medium)
        image.contentTintColor = .controlAccentColor
        addSubview(image)
        imageView = image

        var constraints = [
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 18),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if withEject {
            let eject = NSButton(image: NSImage(systemSymbolName: "eject.fill", accessibilityDescription: String(localized: "推出"))!,
                                 target: nil, action: nil)
            eject.isBordered = false
            eject.contentTintColor = .secondaryLabelColor
            eject.translatesAutoresizingMaskIntoConstraints = false
            eject.toolTip = String(localized: "推出")
            addSubview(eject)
            ejectButton = eject
            constraints += [
                eject.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                eject.centerYAnchor.constraint(equalTo: centerYAnchor),
                text.trailingAnchor.constraint(lessThanOrEqualTo: eject.leadingAnchor, constant: -4),
            ]
        } else {
            constraints.append(text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4))
        }
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
