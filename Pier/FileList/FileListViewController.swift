import AppKit
import PierKit

/// 列表视图中的一个节点。NSOutlineView 靠对象身份追踪展开与选中，所以用类。
@MainActor
final class FileNode: NSObject {
    let object: MTPObject
    /// 子节点；nil 表示还没读取（仅文件夹）
    var children: [FileNode]?
    var loadTask: Task<Void, Never>?

    init(_ object: MTPObject) { self.object = object }

    var name: String { object.name }
    var isFolder: Bool { object.isFolder }
}

/// Finder 式列表视图：可展开文件夹、可排序的列、边读边显示
@MainActor
final class FileListViewController: NSViewController {
    weak var browser: BrowserWindowController?
    var onStatusChange: (() -> Void)?

    private let outlineView = FileOutlineView()
    private let spinner = NSProgressIndicator()
    private let messageLabel = NSTextField(labelWithString: "")

    private var location: BrowserLocation?
    private var session: MTPSession?
    private var rootNodes: [FileNode] = []
    private var displayedNodes: [FileNode] = []
    private var loadTask: Task<Void, Never>?
    private var spinnerTask: Task<Void, Never>?
    private(set) var isLoading = false

    var filterText = "" {
        didSet { if filterText != oldValue { refreshDisplayed() } }
    }

    var displayedCount: Int { displayedNodes.count }
    var selectedCount: Int { outlineView.selectedRowIndexes.count }

    private enum Column {
        static let name = NSUserInterfaceItemIdentifier("name")
        static let size = NSUserInterfaceItemIdentifier("size")
        static let kind = NSUserInterfaceItemIdentifier("kind")
        static let modified = NSUserInterfaceItemIdentifier("modified")
    }

    // MARK: 视图

    override func loadView() {
        func column(_ id: NSUserInterfaceItemIdentifier, _ title: String, width: CGFloat, min: CGFloat, sortKey: String) -> NSTableColumn {
            let c = NSTableColumn(identifier: id)
            c.title = title
            c.width = width
            c.minWidth = min
            c.sortDescriptorPrototype = NSSortDescriptor(key: sortKey, ascending: true)
            return c
        }
        let nameColumn = column(Column.name, String(localized: "名称"), width: 360, min: 120, sortKey: "name")
        let modifiedColumn = column(Column.modified, String(localized: "修改日期"), width: 160, min: 80, sortKey: "modified")
        let sizeColumn = column(Column.size, String(localized: "大小"), width: 90, min: 60, sortKey: "size")
        sizeColumn.headerCell.alignment = .right
        let kindColumn = column(Column.kind, String(localized: "种类"), width: 140, min: 60, sortKey: "kind")
        [nameColumn, modifiedColumn, sizeColumn, kindColumn].forEach(outlineView.addTableColumn)
        outlineView.outlineTableColumn = nameColumn
        modifiedColumn.isHidden = true   // 设备提供日期时才显示

        outlineView.style = .inset
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.allowsMultipleSelection = true
        outlineView.allowsColumnReordering = true
        outlineView.allowsColumnResizing = true
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.autosaveName = "PierFileList"
        outlineView.autosaveTableColumns = true
        outlineView.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClicked(_:))
        outlineView.menu = NSMenu()
        outlineView.menu?.delegate = self
        outlineView.headerView?.menu = headerMenu()

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.isHidden = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        root.addSubview(spinner)
        root.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            messageLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -40),
        ])
        view = root
    }

    private func headerMenu() -> NSMenu {
        let menu = NSMenu()
        for column in outlineView.tableColumns where column.identifier != Column.name {
            let item = menu.addItem(withTitle: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.representedObject = column
            item.target = self
        }
        menu.delegate = self
        return menu
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        (sender.representedObject as? NSTableColumn)?.isHidden.toggle()
    }

    // MARK: 加载

    /// 显示某个位置的内容。切换位置会立即取消上一次的读取。
    func load(_ location: BrowserLocation?) {
        _ = view
        loadTask?.cancel()
        rootNodes.forEach(cancelLoads)
        self.location = location
        rootNodes = []
        refreshDisplayed()
        setMessage(nil)

        guard let location, let (device, _) = location.resolved, let session = device.session else {
            self.session = nil
            setLoading(false)
            return
        }
        self.session = session
        setLoading(true)
        loadTask = Task { [weak self] in
            do {
                for try await batch in session.listChildren(storage: location.storageID, parent: location.folderHandle) {
                    guard let self, !Task.isCancelled else { return }
                    self.rootNodes += batch.map(FileNode.init)
                    self.refreshDisplayed()
                }
                guard let self, !Task.isCancelled else { return }
                self.setLoading(false)
                if self.rootNodes.isEmpty { self.setMessage(String(localized: "文件夹为空")) }
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.setLoading(false)
                self.setMessage(String(localized: "无法读取此文件夹：\(String(describing: error))"))
            }
        }
    }

    private func cancelLoads(_ node: FileNode) {
        node.loadTask?.cancel()
        node.children?.forEach(cancelLoads)
    }

    /// 展开文件夹时按需读取子项
    private func loadChildren(of node: FileNode) {
        guard node.children == nil, node.loadTask == nil, let session, let location else { return }
        node.loadTask = Task { [weak self, weak node] in
            var collected: [MTPObject] = []
            do {
                for try await batch in session.listChildren(storage: location.storageID, parent: node?.object.handle ?? 0) {
                    collected += batch
                }
            } catch {
                collected = []
            }
            guard let self, let node, !Task.isCancelled else { return }
            node.children = self.sorted(collected.map(FileNode.init))
            node.loadTask = nil
            self.outlineView.reloadItem(node, reloadChildren: true)
        }
    }

    private func setLoading(_ loading: Bool) {
        isLoading = loading
        spinnerTask?.cancel()
        if loading {
            // 延迟显示，避免快速加载时闪烁
            spinnerTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled, self.isLoading, self.rootNodes.isEmpty else { return }
                self.spinner.startAnimation(nil)
            }
        } else {
            spinner.stopAnimation(nil)
        }
        onStatusChange?()
    }

    private func setMessage(_ text: String?) {
        messageLabel.stringValue = text ?? ""
        messageLabel.isHidden = text == nil
    }

    // MARK: 排序与过滤

    private func refreshDisplayed() {
        let selected = Set(selectedNodes.map(\.object.handle))
        var nodes = rootNodes
        if !filterText.isEmpty {
            nodes = nodes.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
        }
        displayedNodes = sorted(nodes)
        if !rootNodes.isEmpty { spinner.stopAnimation(nil) }
        outlineView.tableColumns.first { $0.identifier == Column.modified }?.isHidden =
            !rootNodes.contains { $0.object.modified != nil }
        outlineView.reloadData()
        let rows = IndexSet(displayedNodes.enumerated().filter { selected.contains($0.element.object.handle) }.map(\.offset))
        outlineView.selectRowIndexes(rows, byExtendingSelection: false)
        onStatusChange?()
    }

    private func sorted(_ nodes: [FileNode]) -> [FileNode] {
        guard let descriptor = outlineView.sortDescriptors.first, let key = descriptor.key else { return nodes }
        let asc = descriptor.ascending
        func byName(_ a: FileNode, _ b: FileNode) -> Bool {
            a.name.localizedStandardCompare(b.name) == (asc ? .orderedAscending : .orderedDescending)
        }
        return nodes.sorted { a, b in
            switch key {
            case "size":
                if a.object.size != b.object.size { return asc ? a.object.size < b.object.size : a.object.size > b.object.size }
            case "kind":
                let ka = FileTypes.kind(forName: a.name, isFolder: a.isFolder), kb = FileTypes.kind(forName: b.name, isFolder: b.isFolder)
                if ka != kb { return (ka.localizedStandardCompare(kb) == .orderedAscending) == asc }
            case "modified":
                let da = a.object.modified ?? .distantPast, db = b.object.modified ?? .distantPast
                if da != db { return asc ? da < db : da > db }
            default:
                break
            }
            return byName(a, b)
        }
    }

    // MARK: 选择与打开

    private var selectedNodes: [FileNode] {
        outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? FileNode }
    }

    /// 右键点在未选中的行上时，操作对象是被点的那一行（Finder 行为）
    private var actionNodes: [FileNode] {
        let clicked = outlineView.clickedRow
        if clicked >= 0, !outlineView.selectedRowIndexes.contains(clicked), let node = outlineView.item(atRow: clicked) as? FileNode {
            return [node]
        }
        return selectedNodes
    }

    private func location(for node: FileNode) -> BrowserLocation? {
        guard node.isFolder, var base = location else { return nil }
        // 展开的子文件夹里的节点：从根节点往下拼出完整路径
        var chain: [FileNode] = [node]
        var current: Any? = outlineView.parent(forItem: node)
        while let parent = current as? FileNode {
            chain.insert(parent, at: 0)
            current = outlineView.parent(forItem: parent)
        }
        for n in chain { base = base.appending(.init(handle: n.object.handle, name: n.name)) }
        return base
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard outlineView.clickedRow >= 0, let node = outlineView.item(atRow: outlineView.clickedRow) as? FileNode else { return }
        open(node, inNewTab: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
    }

    private func open(_ node: FileNode, inNewTab: Bool) {
        guard let target = location(for: node) else {
            NSSound.beep()   // 打开文件（下载到缓存后用默认 app 打开）在下一阶段实现
            return
        }
        if inNewTab { browser?.openInNewTab(target) } else { browser?.navigate(to: target) }
    }
}

// MARK: - 动作（响应链）

extension FileListViewController: BrowserActions, NSMenuItemValidation {
    @objc func openSelection(_ sender: Any?) {
        guard let node = actionNodes.first else { return }
        open(node, inNewTab: false)
    }

    @objc func openSelectionInNewTab(_ sender: Any?) {
        actionNodes.filter(\.isFolder).forEach { open($0, inNewTab: true) }
    }

    // 以下在后续阶段实现
    @objc func newFolder(_ sender: Any?) {}
    @objc func getInfo(_ sender: Any?) {}
    @objc func downloadSelection(_ sender: Any?) {}
    @objc func upload(_ sender: Any?) {}
    @objc func deleteSelection(_ sender: Any?) {}
    @objc func copy(_ sender: Any?) {}
    @objc func paste(_ sender: Any?) {}

    // 导航类动作交给窗口控制器
    @objc func goBack(_ sender: Any?) { browser?.goBack(sender) }
    @objc func goForward(_ sender: Any?) { browser?.goForward(sender) }
    @objc func goToEnclosingFolder(_ sender: Any?) { browser?.goToEnclosingFolder(sender) }
    @objc func reload(_ sender: Any?) { browser?.reload(sender) }
    @objc func ejectDevice(_ sender: Any?) { browser?.ejectDevice(sender) }
    @objc func focusSearch(_ sender: Any?) { browser?.focusSearch(sender) }
    @objc func showAsIcons(_ sender: Any?) { browser?.showAsIcons(sender) }
    @objc func showAsList(_ sender: Any?) { browser?.showAsList(sender) }
    @objc func togglePathBar(_ sender: Any?) { browser?.togglePathBar(sender) }
    @objc func toggleStatusBar(_ sender: Any?) { browser?.toggleStatusBar(sender) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(openSelection(_:)):
            return actionNodes.count == 1 && actionNodes[0].isFolder
        case #selector(openSelectionInNewTab(_:)):
            return actionNodes.contains(where: \.isFolder)
        case #selector(newFolder(_:)), #selector(getInfo(_:)), #selector(downloadSelection(_:)), #selector(upload(_:)),
             #selector(deleteSelection(_:)), #selector(copy(_:)), #selector(paste(_:)):
            return false
        default:
            return browser?.validateMenuItem(item) ?? false
        }
    }
}

// MARK: - 右键菜单

extension FileListViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === outlineView.menu else {
            // 表头菜单：同步各列的勾选状态
            for item in menu.items { item.state = ((item.representedObject as? NSTableColumn)?.isHidden == false) ? .on : .off }
            return
        }
        menu.removeAllItems()
        guard !actionNodes.isEmpty else {
            menu.addItem(withTitle: String(localized: "新建文件夹"), action: #selector(newFolder(_:)), keyEquivalent: "")
            menu.addItem(withTitle: String(localized: "刷新"), action: #selector(reload(_:)), keyEquivalent: "")
            return
        }
        menu.addItem(withTitle: String(localized: "打开"), action: #selector(openSelection(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "在新标签页中打开"), action: #selector(openSelectionInNewTab(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "下载到…"), action: #selector(downloadSelection(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "显示简介"), action: #selector(getInfo(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "拷贝"), action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "删除"), action: #selector(deleteSelection(_:)), keyEquivalent: "")
    }
}

// MARK: - NSOutlineViewDataSource / Delegate

extension FileListViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileNode else { return displayedNodes.count }
        if node.children == nil { loadChildren(of: node) }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FileNode else { return displayedNodes[index] }
        return node.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isFolder ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        refreshDisplayed()
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        onStatusChange?()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode, let column = tableColumn else { return nil }
        let cell = makeCell(column.identifier, withImage: column.identifier == Column.name)
        let field = cell.textField!
        switch column.identifier {
        case Column.name:
            field.stringValue = node.name
            cell.imageView?.image = FileTypes.icon(forName: node.name, isFolder: node.isFolder)
        case Column.size:
            field.stringValue = node.isFolder ? "--" : Format.bytes(node.object.size)
            field.alignment = .right
        case Column.kind:
            field.stringValue = FileTypes.kind(forName: node.name, isFolder: node.isFolder)
        case Column.modified:
            field.stringValue = Format.date(node.object.modified)
        default:
            break
        }
        if column.identifier != Column.name { field.textColor = .secondaryLabelColor }
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier, withImage: Bool) -> NSTableCellView {
        if let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView { return cell }
        let cell = NSTableCellView()
        cell.identifier = id
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        var constraints = [
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
        ]
        if withImage {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            constraints += [
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
            ]
        } else {
            constraints.append(text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
        }
        NSLayoutConstraint.activate(constraints)
        return cell
    }
}

/// 处理 Finder 式键盘操作：⌘↓ 打开、回车（以后用于改名）
@MainActor
final class FileOutlineView: NSOutlineView {
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.specialKey == .downArrow {
            NSApp.sendAction(#selector(BrowserActions.openSelection(_:)), to: nil, from: self)
            return
        }
        super.keyDown(with: event)
    }
}
