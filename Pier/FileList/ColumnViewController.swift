import AppKit
import PierKit

/// 分栏视图（Finder 式）：选中文件夹在右边展开下一栏，选中文件在最右边显示预览。
/// 每一栏是一个单列表格，横向排开，可以左右滚动。
@MainActor
final class ColumnViewController: NSViewController, FileBrowsingView {
    weak var host: FileViewHost?

    static let columnWidth: CGFloat = 240

    private let scrollView = NSScrollView()
    /// 各栏按固定宽度横排在这个视图里（手动排布 frame：滚动视图里用 Auto Layout 撑高度不可靠）
    private let container = FlippedView()
    private var columns: [BrowserColumn] = []
    private var preview: ColumnPreview?
    /// 最近操作的一栏（键盘焦点所在，或最近改变选择的那一栏）
    private weak var activeColumn: BrowserColumn?
    /// 右键菜单所在的一栏
    private weak var menuColumn: BrowserColumn?
    private let thumbnails = ThumbnailRequests()

    private var contents: FolderContents? { host?.contents }

    override func loadView() {
        scrollView.documentView = container
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        view = scrollView
        pushColumn(parent: nil)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutColumns()
    }

    /// 从左到右排开各栏和预览，高度等于可见区域
    private func layoutColumns() {
        let height = scrollView.contentView.bounds.height
        var x: CGFloat = 0
        for column in columns {
            column.frame = NSRect(x: x, y: 0, width: Self.columnWidth, height: height)
            x += Self.columnWidth
        }
        if let preview {
            let width = max(Self.columnWidth + 40, scrollView.contentView.bounds.width - x)
            preview.frame = NSRect(x: x, y: 0, width: width, height: height)
            x += width
        }
        container.frame = NSRect(x: 0, y: 0, width: max(x, scrollView.contentView.bounds.width), height: height)
    }

    // MARK: 栏的增减

    @discardableResult
    private func pushColumn(parent: FileNode?) -> BrowserColumn {
        removePreview()
        let column = BrowserColumn(parent: parent, owner: self)
        column.nodes = parent == nil ? (contents?.displayedNodes ?? []) : (parent?.children ?? [])
        columns.append(column)
        container.addSubview(column)
        layoutColumns()
        if let parent, parent.children == nil { contents?.loadChildren(of: parent) }
        column.reload()
        scrollToEnd()
        return column
    }

    /// 去掉 `column` 右边的所有栏
    private func truncate(after column: BrowserColumn) {
        guard let index = columns.firstIndex(where: { $0 === column }) else { return }
        for extra in columns[(index + 1)...] { extra.removeFromSuperview() }
        columns.removeSubrange((index + 1)...)
        removePreview()
        layoutColumns()
    }

    private func removePreview() {
        preview?.removeFromSuperview()
        preview = nil
    }

    private func showPreview(for node: FileNode) {
        removePreview()
        let p = ColumnPreview(node: node)
        container.addSubview(p)
        preview = p
        layoutColumns()
        thumbnails.request(node, device: contents?.device, size: 256) { [weak self, weak p] node in
            guard self?.preview === p else { return }
            p?.update(icon: node.displayIcon)
        }
        scrollToEnd()
    }

    private func scrollToEnd() {
        let width = container.frame.width
        let visible = scrollView.contentView.bounds.width
        if width > visible {
            scrollView.contentView.scroll(to: NSPoint(x: width - visible, y: 0))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    // MARK: 栏的回调

    fileprivate func columnSelectionDidChange(_ column: BrowserColumn) {
        activeColumn = column
        truncate(after: column)
        let selected = column.selectedNodes
        if selected.count == 1, let node = selected.first {
            if node.isFolder && contents?.searchQuery == nil {
                pushColumn(parent: node)
            } else if !node.isFolder {
                showPreview(for: node)
            }
        }
        host?.selectionDidChange()
    }

    fileprivate func columnDidBecomeActive(_ column: BrowserColumn) {
        activeColumn = column
    }

    fileprivate func columnWantsMenu(_ column: BrowserColumn) {
        menuColumn = column
    }

    /// ← → 在栏之间移动
    fileprivate func moveFocus(from column: BrowserColumn, by delta: Int) {
        guard let index = columns.firstIndex(where: { $0 === column }) else { return }
        let target = index + delta
        guard columns.indices.contains(target) else { return }
        let next = columns[target]
        if delta > 0, next.table.selectedRow < 0, let first = next.firstNodeRow {
            next.table.selectRowIndexes([first], byExtendingSelection: false)
        }
        view.window?.makeFirstResponder(next.table)
        activeColumn = next
    }

    fileprivate func open(_ node: FileNode) {
        host?.open(node, inNewTab: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
    }

    fileprivate func populateMenu(_ menu: NSMenu, column: BrowserColumn) {
        menuColumn = column
        host?.populateContextMenu(menu, for: actionNodes)
    }

    fileprivate func pasteboardWriter(for node: FileNode) -> NSPasteboardWriting? { host?.pasteboardWriter(for: node) }
    fileprivate func validateDrop(_ info: NSDraggingInfo, onto node: FileNode?) -> NSDragOperation { host?.validateDrop(info, onto: node) ?? [] }
    fileprivate func acceptDrop(_ info: NSDraggingInfo, onto node: FileNode?) -> Bool { host?.acceptDrop(info, onto: node) ?? false }
    fileprivate var isSearching: Bool { contents?.searchQuery != nil }
    fileprivate func groups(for nodes: [FileNode]) -> [FileGroup] { contents?.groups(for: nodes) ?? [FileGroup(title: "", nodes: nodes)] }

    // MARK: FileBrowsingView

    func contentsDidChange(_ change: FolderContents.Change) {
        guard isViewLoaded, let contents else { return }
        switch change {
        case .reload:
            guard let first = columns.first else { return }
            first.nodes = contents.displayedNodes
            first.reload()
            // 后面各栏的文件夹不在了就收起
            for (index, column) in columns.enumerated().dropFirst() {
                guard let parent = column.parent, columns[index - 1].nodes.contains(where: { $0 === parent }) else {
                    truncate(after: columns[index - 1])
                    break
                }
                column.nodes = parent.children ?? []
                column.reload()
            }
            if contents.displayedNodes.isEmpty { truncate(after: first) }
        case let .children(node):
            for column in columns where column.parent === node {
                column.nodes = node.children ?? []
                column.reload()
            }
        case .status:
            break
        }
    }

    var selectedNodes: [FileNode] {
        (activeColumn ?? columns.last(where: { !$0.selectedNodes.isEmpty }) ?? columns.first)?.selectedNodes ?? []
    }

    var actionNodes: [FileNode] {
        if let column = menuColumn, column.table.clickedRow >= 0 {
            let clicked = column.table.clickedRow
            if column.table.selectedRowIndexes.contains(clicked) { return column.selectedNodes }
            return column.node(atRow: clicked).map { [$0] } ?? []
        }
        return selectedNodes
    }

    func select(_ nodes: [FileNode]) {
        // 选中的节点可能在任何一栏里，从右往左找
        for column in columns.reversed() {
            let rows = IndexSet(nodes.compactMap(column.row(of:)))
            guard !rows.isEmpty else { continue }
            column.table.selectRowIndexes(rows, byExtendingSelection: false)
            column.table.scrollRowToVisible(rows.first!)
            activeColumn = column
            return
        }
    }

    func beginRename(_ node: FileNode) {
        guard let window = view.window else { return }
        select([node])
        RenamePrompt.run(node, in: window, host: host)
    }

    func focus() {
        guard let column = activeColumn ?? columns.first else { return }
        view.window?.makeFirstResponder(column.table)
    }

    func screenRect(for node: FileNode) -> NSRect? {
        for column in columns {
            guard let row = column.row(of: node),
                  let cell = column.table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
                  let image = cell.imageView, let window = view.window else { continue }
            return window.convertToScreen(image.convert(image.bounds, to: nil))
        }
        return nil
    }
}

// MARK: - 一栏

@MainActor
private final class BrowserColumn: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let parent: FileNode?
    let table = ColumnTableView()
    /// 这一栏的项目（已排序）；设置时按当前分组规则生成行
    var nodes: [FileNode] = [] { didSet { rebuildRows() } }
    private unowned let owner: ColumnViewController

    /// 表格的一行：分组标题或项目
    private enum Row {
        case header(FileGroup)
        case node(FileNode)
    }
    private var rows: [Row] = []

    private func rebuildRows() {
        let groups = owner.groups(for: nodes)
        if groups.count == 1, groups[0].title.isEmpty {
            rows = nodes.map(Row.node)
        } else {
            rows = groups.flatMap { [Row.header($0)] + $0.nodes.map(Row.node) }
        }
    }

    func node(atRow row: Int) -> FileNode? {
        guard rows.indices.contains(row), case let .node(node) = rows[row] else { return nil }
        return node
    }

    func row(of node: FileNode) -> Int? {
        rows.firstIndex { if case let .node(n) = $0 { n === node } else { false } }
    }

    /// 第一个项目所在的行（跳过分组标题）
    var firstNodeRow: Int? { rows.firstIndex { if case .node = $0 { true } else { false } } }

    init(parent: FileNode?, owner: ColumnViewController) {
        self.parent = parent
        self.owner = owner
        super.init(frame: .zero)

        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.rowSizeStyle = .default
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        table.menu = NSMenu()
        table.menu?.delegate = self
        table.registerForDraggedTypes([.fileURL, .pierItem])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask([.move, .copy, .link], forLocal: true)
        table.column = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        // 栏与栏之间的分隔线
        let separator = NSBox.separator()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: separator.leadingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var selectedNodes: [FileNode] {
        table.selectedRowIndexes.compactMap(node(atRow:))
    }

    func reload() {
        let selected = selectedNodes
        rebuildRows()   // 分组方式可能变了
        table.reloadData()
        let rows = IndexSet(selected.compactMap(row(of:)))
        // 恢复选择时不要触发展开 / 收起
        suppressSelectionCallback = true
        table.selectRowIndexes(rows, byExtendingSelection: false)
        suppressSelectionCallback = false
    }

    private var suppressSelectionCallback = false

    @objc private func doubleClicked(_ sender: Any?) {
        guard let node = node(atRow: table.clickedRow) else { return }
        owner.open(node)
    }

    fileprivate func becameActive() { owner.columnDidBecomeActive(self) }
    fileprivate func moveFocus(by delta: Int) { owner.moveFocus(from: self, by: delta) }

    // MARK: 数据

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { node(atRow: row) != nil }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if case let .header(group) = rows[row] {
            let cell = (tableView.makeView(withIdentifier: GroupHeaderCell.identifier, owner: nil) as? GroupHeaderCell) ?? GroupHeaderCell()
            cell.configure(title: group.title, count: group.nodes.count)
            return cell
        }
        let cell = (tableView.makeView(withIdentifier: ColumnCell.identifier, owner: nil) as? ColumnCell) ?? ColumnCell()
        guard let node = node(atRow: row) else { return cell }
        cell.textField?.stringValue = node.name
        cell.imageView?.image = node.displayIcon
        cell.showsDisclosure = node.isFolder && !owner.isSearching
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallback else { return }
        owner.columnSelectionDidChange(self)
    }

    // MARK: 右键菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        owner.populateMenu(menu, column: self)
    }

    // MARK: 拖放

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        node(atRow: row).flatMap(owner.pasteboardWriter(for:))
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if dropOperation == .on, let folder = node(atRow: row), folder.isFolder {
            return owner.validateDrop(info, onto: folder)
        }
        // 放在空白处或文件上 = 放进这一栏所在的文件夹
        if parent == nil && owner.isSearching { return [] }
        tableView.setDropRow(-1, dropOperation: .on)
        return owner.validateDrop(info, onto: parent)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let target = node(atRow: row).flatMap { $0.isFolder ? $0 : nil } ?? parent
        return owner.acceptDrop(info, onto: target)
    }
}

/// 栏里的表格：← → 在栏之间移动，其余按键与列表视图一致
@MainActor
private final class ColumnTableView: NSTableView {
    weak var column: BrowserColumn?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { column?.becameActive() }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        if FileViewKeys.handle(event, from: self) { return }
        if event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            switch event.specialKey {
            case .rightArrow?: column?.moveFocus(by: 1); return
            case .leftArrow?: column?.moveFocus(by: -1); return
            default: break
            }
        }
        super.keyDown(with: event)
    }
}

/// 一行：图标 + 名字 + 文件夹的 ›
@MainActor
private final class ColumnCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ColumnCell")

    private let disclosure = NSImageView()

    var showsDisclosure = false { didSet { disclosure.isHidden = !showsDisclosure } }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        disclosure.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        disclosure.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        disclosure.contentTintColor = .tertiaryLabelColor
        for v in [image, text, disclosure] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        imageView = image
        textField = text
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: disclosure.leadingAnchor, constant: -4),
            disclosure.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            disclosure.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// 选中文件时最右边的预览栏：大图标（图片显示缩略图）、名字、种类和大小
@MainActor
private final class ColumnPreview: NSView {
    private let imageView = NSImageView()

    init(node: FileNode) {
        super.init(frame: .zero)

        imageView.image = node.displayIcon
        imageView.imageScaling = .scaleProportionallyUpOrDown
        let name = NSTextField(wrappingLabelWithString: node.name)
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        name.alignment = .center
        name.isSelectable = true
        let detail = NSTextField(labelWithString: node.kindAndSize)
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center

        let stack = NSStackView(views: [imageView, name, detail])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 160),
            imageView.heightAnchor.constraint(equalToConstant: 160),
            name.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 40),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(icon: NSImage) { imageView.image = icon }
}

/// 左上角为原点，各栏从顶部开始排
@MainActor
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
