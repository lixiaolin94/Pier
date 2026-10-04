import AppKit
import PierKit

/// Finder 式列表视图：可展开文件夹、可排序的列、行内改名、拖放
@MainActor
final class FileListViewController: NSViewController, FileBrowsingView {
    weak var host: FileViewHost?

    private let outlineView = FileOutlineView()
    /// 正在行内改名的节点
    private var renaming: FileNode?

    private var contents: FolderContents? { host?.contents }

    private enum Column {
        static let name = NSUserInterfaceItemIdentifier("name")
        static let size = NSUserInterfaceItemIdentifier("size")
        static let kind = NSUserInterfaceItemIdentifier("kind")
        static let modified = NSUserInterfaceItemIdentifier("modified")
        static let location = NSUserInterfaceItemIdentifier("location")
    }

    // MARK: 视图

    override func loadView() {
        func column(_ id: NSUserInterfaceItemIdentifier, _ title: String, width: CGFloat, min: CGFloat, sortKey: String?) -> NSTableColumn {
            let c = NSTableColumn(identifier: id)
            c.title = title
            c.width = width
            c.minWidth = min
            if let sortKey { c.sortDescriptorPrototype = NSSortDescriptor(key: sortKey, ascending: true) }
            return c
        }
        let nameColumn = column(Column.name, String(localized: "名称"), width: 360, min: 120, sortKey: "name")
        let modifiedColumn = column(Column.modified, String(localized: "修改日期"), width: 160, min: 80, sortKey: "modified")
        let sizeColumn = column(Column.size, String(localized: "大小"), width: 90, min: 60, sortKey: "size")
        sizeColumn.headerCell.alignment = .right
        let kindColumn = column(Column.kind, String(localized: "种类"), width: 140, min: 60, sortKey: "kind")
        let locationColumn = column(Column.location, String(localized: "位置"), width: 200, min: 80, sortKey: nil)
        [nameColumn, modifiedColumn, sizeColumn, kindColumn, locationColumn].forEach(outlineView.addTableColumn)
        outlineView.outlineTableColumn = nameColumn
        modifiedColumn.isHidden = true   // 设备提供日期时才显示
        locationColumn.isHidden = true   // 只在搜索结果里显示

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
        outlineView.registerForDraggedTypes([.fileURL, .pierItem])
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)
        outlineView.setDraggingSourceOperationMask([.move, .copy, .link], forLocal: true)
        outlineView.draggingDestinationFeedbackStyle = .regular
        outlineView.floatsGroupRows = true   // 分组标题滚动时停在顶部，和 Finder 一样

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        view = scroll
    }

    private func headerMenu() -> NSMenu {
        let menu = NSMenu()
        for column in outlineView.tableColumns where column.identifier != Column.name && column.identifier != Column.location {
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

    // MARK: FileBrowsingView

    func contentsDidChange(_ change: FolderContents.Change) {
        guard isViewLoaded, let contents else { return }
        switch change {
        case .reload:
            let selected = Set(selectedNodes.map(ObjectIdentifier.init))
            outlineView.tableColumns.first { $0.identifier == Column.modified }?.isHidden = !contents.hasDates
            outlineView.tableColumns.first { $0.identifier == Column.location }?.isHidden = contents.searchQuery == nil
            if outlineView.sortDescriptors != contents.sortDescriptors { outlineView.sortDescriptors = contents.sortDescriptors }
            outlineView.compensatesGroupIndent = contents.isGrouped
            outlineView.reloadData()
            if contents.isGrouped { contents.groups.forEach { outlineView.expandItem($0) } }
            restoreExpansion(contents.displayedNodes)
            var rows = IndexSet()
            for row in 0..<outlineView.numberOfRows {
                if let node = outlineView.item(atRow: row) as? FileNode, selected.contains(ObjectIdentifier(node)) { rows.insert(row) }
            }
            outlineView.selectRowIndexes(rows, byExtendingSelection: false)
        case let .children(node):
            outlineView.reloadItem(node, reloadChildren: true)
        case .status:
            break
        }
    }

    /// reloadData 之后恢复之前展开的文件夹
    private func restoreExpansion(_ nodes: [FileNode]) {
        for node in nodes where node.isFolder && node.children != nil && expanded.contains(ObjectIdentifier(node)) {
            outlineView.expandItem(node)
            restoreExpansion(node.children ?? [])
        }
    }

    private var expanded = Set<ObjectIdentifier>()

    var selectedNodes: [FileNode] {
        outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? FileNode }
    }

    var actionNodes: [FileNode] {
        let clicked = outlineView.clickedRow
        if clicked >= 0, !outlineView.selectedRowIndexes.contains(clicked), let node = outlineView.item(atRow: clicked) as? FileNode {
            return [node]
        }
        return selectedNodes
    }

    func select(_ nodes: [FileNode]) {
        let rows = IndexSet(nodes.map { outlineView.row(forItem: $0) }.filter { $0 >= 0 })
        outlineView.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { outlineView.scrollRowToVisible(first) }
    }

    func focus() { view.window?.makeFirstResponder(outlineView) }

    func screenRect(for node: FileNode) -> NSRect? {
        let row = outlineView.row(forItem: node)
        guard row >= 0, let window = view.window,
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
              let image = cell.imageView else { return nil }
        return window.convertToScreen(image.convert(image.bounds, to: nil))
    }

    func beginRename(_ node: FileNode) {
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes([row], byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        guard let cell = outlineView.view(atColumn: outlineView.column(withIdentifier: Column.name), row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }
        renaming = node
        field.isEditable = true
        field.delegate = self
        view.window?.makeFirstResponder(field)
        field.selectBaseName()
    }

    // MARK: 打开

    @objc private func doubleClicked(_ sender: Any?) {
        guard outlineView.clickedRow >= 0, let node = outlineView.item(atRow: outlineView.clickedRow) as? FileNode else { return }
        host?.open(node, inNewTab: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
    }
}

// MARK: - 行内改名

extension FileListViewController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let node = renaming else { return }
        renaming = nil
        field.isEditable = false
        let movement = (obj.userInfo?["NSTextMovement"] as? Int).flatMap(NSTextMovement.init(rawValue:))
        let newName = field.stringValue
        field.stringValue = node.name
        if movement != .cancel, newName != node.name {
            host?.commitRename(node, to: newName)
        }
        focus()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // 不合法的名字直接在编辑框里提示，不结束编辑
        guard selector == #selector(NSResponder.insertNewline(_:)), let node = renaming,
              let problem = host?.renameProblem(node, to: textView.string), textView.string != node.name else { return false }
        NSSound.beep()
        control.toolTip = problem
        showRenameHint(problem, below: control)
        return true
    }

    private func showRenameHint(_ text: String, below control: NSControl) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.preferredMaxLayoutWidth = 260
        let vc = NSViewController()
        let container = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
        ])
        vc.view = container
        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.show(relativeTo: control.bounds, of: control, preferredEdge: .maxY)
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
        host?.populateContextMenu(menu, for: actionNodes)
    }
}

// MARK: - NSOutlineViewDataSource / Delegate

extension FileListViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// 顶层：分组时是各组，否则直接是项目
    private var rootItems: [Any] {
        guard let contents else { return [] }
        return contents.isGrouped ? contents.groups : contents.displayedNodes
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return rootItems.count }
        if let group = item as? FileGroup { return group.nodes.count }
        guard let node = item as? FileNode else { return 0 }
        if node.children == nil { contents?.loadChildren(of: node) }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return rootItems[index] }
        if let group = item as? FileGroup { return group.nodes[index] }
        return (item as! FileNode).children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if item is FileGroup { return true }
        guard let node = item as? FileNode else { return false }
        return node.isFolder && contents?.searchQuery == nil
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is FileGroup }

    // 分组标题不能折叠、不能选中
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { !(item is FileGroup) }
    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool { !(item is FileGroup) }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { !(item is FileGroup) }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? FileNode { expanded.insert(ObjectIdentifier(node)) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? FileNode { expanded.remove(ObjectIdentifier(node)) }
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        contents?.sortDescriptors = outlineView.sortDescriptors
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        host?.selectionDidChange()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? FileGroup {
            let cell = (outlineView.makeView(withIdentifier: GroupHeaderCell.identifier, owner: nil) as? GroupHeaderCell) ?? GroupHeaderCell()
            cell.configure(title: group.title, count: group.nodes.count)
            return cell
        }
        guard let node = item as? FileNode, let column = tableColumn else { return nil }
        let cell = makeCell(column.identifier, withImage: column.identifier == Column.name)
        let field = cell.textField!
        field.isEditable = false
        field.textColor = column.identifier == Column.name ? .labelColor : .secondaryLabelColor
        field.alignment = .natural
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
        case Column.location:
            field.stringValue = node.folderPath.map(\.name).joined(separator: " ▸ ")
        default:
            break
        }
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier, withImage: Bool) -> NSTableCellView {
        if let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView { return cell }
        let cell = NSTableCellView()
        cell.identifier = id
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.cell?.truncatesLastVisibleLine = true
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

    // MARK: 拖放

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? FileNode, renaming == nil else { return nil }
        return host?.pasteboardWriter(for: node)
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        // 放到文件上 = 放到它所在的文件夹；放在行与行之间 = 放到那一层的文件夹
        var target = item as? FileNode   // 放在分组标题上 = 当前文件夹
        if let node = target, !node.isFolder { target = node.parent }
        if contents?.searchQuery != nil && target == nil { return [] }
        outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return host?.validateDrop(info, onto: target) ?? []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        host?.acceptDrop(info, onto: item as? FileNode) ?? false
    }
}

/// 处理 Finder 式键盘操作：⌘↓ 打开、空格 Quick Look、回车改名
@MainActor
final class FileOutlineView: NSOutlineView {
    /// 分组时项目是分组标题的子项，大纲视图会多缩进一级；Finder 不缩进，这里往回挪一级
    var compensatesGroupIndent = false

    private func shift(forRow row: Int) -> CGFloat {
        guard compensatesGroupIndent, level(forRow: row) > 0 else { return 0 }
        return indentationPerLevel
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        let shift = shift(forRow: row)
        if shift > 0, column == self.column(withIdentifier: outlineTableColumn?.identifier ?? .init("")) {
            frame.origin.x -= shift
            frame.size.width += shift
        }
        return frame
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        frame.origin.x -= shift(forRow: row)
        return frame
    }

    override func keyDown(with event: NSEvent) {
        if FileViewKeys.handle(event, from: self) { return }
        super.keyDown(with: event)
    }
}

/// 分组标题行：组名 + 项目数（列表、分栏视图共用）
@MainActor
final class GroupHeaderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("GroupHeaderCell")

    private let countLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        title.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        countLabel.textColor = .tertiaryLabelColor
        for v in [title, countLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        textField = title
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 6),
            countLabel.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, count: Int) {
        textField?.stringValue = title
        countLabel.stringValue = String(localized: "\(count) 项")
    }
}
