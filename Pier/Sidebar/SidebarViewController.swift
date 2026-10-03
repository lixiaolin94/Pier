import AppKit
import PierKit

/// 侧边栏条目。NSOutlineView 需要引用类型，并且靠对象身份追踪展开状态，所以设备节点在重建时尽量复用。
@MainActor
final class SidebarItem: NSObject {
    enum Kind {
        case group(String)
        case device(MTPDevice)
        case storage(MTPDevice, MTPStorage)
        case placeholder(String)
    }

    let kind: Kind
    var children: [SidebarItem] = []

    init(_ kind: Kind, children: [SidebarItem] = []) {
        self.kind = kind
        self.children = children
    }

    var location: BrowserLocation? {
        if case let .storage(device, storage) = kind { return BrowserLocation(deviceID: device.id, storageID: storage.id) }
        return nil
    }
}

@MainActor
final class SidebarViewController: NSViewController {
    weak var browser: BrowserWindowController?

    private let outlineView = NSOutlineView()
    private var groups: [SidebarItem] = []
    /// 程序化设置选中时，不要反过来触发导航
    private var suppressSelectionNavigation = false
    private var lastLocation: BrowserLocation?

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

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(devicesDidChange(_:)),
                                               name: DeviceManager.devicesDidChange, object: nil)
        rebuild()
    }

    // MARK: 数据

    @objc private func devicesDidChange(_ note: Notification) { rebuild() }

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
        groups = [SidebarItem(.group(String(localized: "设备")), children: deviceItems)]
        // 收藏分组在后续版本加入

        outlineView.reloadData()
        for group in groups {
            outlineView.expandItem(group)
            group.children.forEach { outlineView.expandItem($0) }
        }
        select(lastLocation)
    }

    /// 根据当前浏览位置高亮对应的存储（不触发导航）
    func select(_ location: BrowserLocation?) {
        lastLocation = location
        suppressSelectionNavigation = true
        defer { suppressSelectionNavigation = false }
        let target = location.map { ($0.deviceID, $0.storageID) }
        for row in 0..<outlineView.numberOfRows {
            if let item = outlineView.item(atRow: row) as? SidebarItem, let l = item.location,
               let target, l.deviceID == target.0, l.storageID == target.1 {
                outlineView.selectRowIndexes([row], byExtendingSelection: false)
                return
            }
        }
        outlineView.deselectAll(nil)
    }

    // MARK: 交互

    @objc private func rowClicked(_ sender: NSOutlineView) {
        // ⌘单击：在新 tab 中打开，当前 tab 保持不动
        guard NSApp.currentEvent?.modifierFlags.contains(.command) == true,
              let item = outlineView.item(atRow: outlineView.clickedRow) as? SidebarItem,
              let location = item.location else { return }
        select(lastLocation)
        browser?.openInNewTab(location)
    }

    @objc private func ejectClicked(_ sender: NSButton) {
        let row = outlineView.row(for: sender)
        guard let item = outlineView.item(atRow: row) as? SidebarItem, case let .device(device) = item.kind else { return }
        DeviceManager.shared.eject(device)
    }

    @objc private func openInNewTab(_ sender: NSMenuItem) {
        if let location = (sender.representedObject as? SidebarItem)?.location { browser?.openInNewTab(location) }
    }

    @objc private func openAllStoragesInTabs(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? SidebarItem else { return }
        let locations = item.children.compactMap(\.location)
        guard let first = locations.first else { return }
        browser?.navigate(to: first)
        locations.dropFirst().forEach { browser?.openInNewTab($0) }
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
        (item as? SidebarItem)?.location != nil
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        if case .device = (item as? SidebarItem)?.kind { return true }
        return false
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionNavigation,
              let item = outlineView.item(atRow: outlineView.selectedRow) as? SidebarItem,
              let location = item.location else { return }
        lastLocation = location
        browser?.navigate(to: location)
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
            cell.imageView?.image = NSImage(systemSymbolName: Self.symbol(for: device), accessibilityDescription: nil)
            cell.ejectButton?.target = self
            cell.ejectButton?.action = #selector(ejectClicked(_:))
            if case .connecting = device.state { cell.ejectButton?.isHidden = true } else { cell.ejectButton?.isHidden = false }
            return cell
        case let .storage(_, storage):
            let cell = reuse(.init("storage")) { SidebarCell(header: false) }
            cell.textField?.stringValue = storage.displayName
            let symbol = storage.displayName.localizedCaseInsensitiveContains("SD") ? "sdcard" : "internaldrive"
            cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            cell.toolTip = String(localized: "剩余 \(Format.bytes(storage.info.freeSpace))，共 \(Format.bytes(storage.info.maxCapacity))")
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
}

// MARK: - 右键菜单

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let item = outlineView.item(atRow: outlineView.clickedRow) as? SidebarItem else { return }
        switch item.kind {
        case .storage:
            let open = menu.addItem(withTitle: String(localized: "在新标签页中打开"), action: #selector(openInNewTab(_:)), keyEquivalent: "")
            open.representedObject = item
            open.target = self
        case .device:
            let all = menu.addItem(withTitle: String(localized: "在标签页中打开所有存储"), action: #selector(openAllStoragesInTabs(_:)), keyEquivalent: "")
            all.representedObject = item
            all.target = self
            menu.addItem(.separator())
            let eject = menu.addItem(withTitle: String(localized: "推出"), action: #selector(ejectFromMenu(_:)), keyEquivalent: "")
            eject.representedObject = item
            eject.target = self
        default:
            break
        }
    }

    @objc private func ejectFromMenu(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? SidebarItem, case let .device(device) = item.kind else { return }
        DeviceManager.shared.eject(device)
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
