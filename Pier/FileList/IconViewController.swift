import AppKit
import PierKit

/// 图标视图：大图标网格，图片在后台低优先级生成缩略图；分组时每组一个带标题的分区
@MainActor
final class IconViewController: NSViewController, FileBrowsingView {
    weak var host: FileViewHost?

    private let collectionView = IconCollectionView()
    private let layout = NSCollectionViewFlowLayout()
    private let thumbnails = ThumbnailRequests()
    private var contents: FolderContents? { host?.contents }
    private var groups: [FileGroup] { contents?.groups ?? [] }

    private func node(at path: IndexPath) -> FileNode? {
        guard groups.indices.contains(path.section), groups[path.section].nodes.indices.contains(path.item) else { return nil }
        return groups[path.section].nodes[path.item]
    }

    private func indexPath(of node: FileNode) -> IndexPath? {
        for (section, group) in groups.enumerated() {
            if let item = group.nodes.firstIndex(where: { $0 === node }) { return IndexPath(item: item, section: section) }
        }
        return nil
    }

    override func loadView() {
        layout.itemSize = NSSize(width: 104, height: 104)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.controlBackgroundColor]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(IconItem.self, forItemWithIdentifier: IconItem.identifier)
        collectionView.register(SectionHeaderView.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                withIdentifier: SectionHeaderView.identifier)
        collectionView.registerForDraggedTypes([.fileURL, .pierItem])
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)
        collectionView.setDraggingSourceOperationMask([.move, .copy, .link], forLocal: true)
        collectionView.menu = NSMenu()
        collectionView.menu?.delegate = self
        collectionView.onDoubleClick = { [weak self] path in
            guard let self, let node = self.node(at: path) else { return }
            self.host?.open(node, inNewTab: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
        }

        let scroll = NSScrollView()
        scroll.documentView = collectionView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        view = scroll
    }

    // MARK: FileBrowsingView

    func contentsDidChange(_ change: FolderContents.Change) {
        guard isViewLoaded, case .reload = change else { return }
        let selected = selectedNodes
        // 换了文件夹：之前排队的缩略图不要了
        thumbnails.keep(only: contents?.displayedNodes ?? [])
        let grouped = contents?.isGrouped ?? false
        layout.headerReferenceSize = NSSize(width: 0, height: grouped ? 30 : 0)
        layout.sectionInset = NSEdgeInsets(top: grouped ? 4 : 12, left: 12, bottom: grouped ? 16 : 12, right: 12)
        collectionView.reloadData()
        collectionView.selectionIndexPaths = Set(selected.compactMap(indexPath(of:)))
    }

    var selectedNodes: [FileNode] {
        collectionView.selectionIndexPaths.sorted().compactMap(node(at:))
    }

    var actionNodes: [FileNode] {
        if let clicked = collectionView.clickedIndexPath, let node = node(at: clicked),
           !collectionView.selectionIndexPaths.contains(clicked) {
            return [node]
        }
        return selectedNodes
    }

    func select(_ selection: [FileNode]) {
        let paths = Set(selection.compactMap(indexPath(of:)))
        collectionView.selectionIndexPaths = paths
        if !paths.isEmpty { collectionView.scrollToItems(at: paths, scrollPosition: .nearestHorizontalEdge) }
        host?.selectionDidChange()
    }

    func focus() { view.window?.makeFirstResponder(collectionView) }

    func screenRect(for node: FileNode) -> NSRect? {
        guard let path = indexPath(of: node), let window = view.window,
              let item = collectionView.item(at: path) as? IconItem, let image = item.imageView else { return nil }
        return window.convertToScreen(image.convert(image.bounds, to: nil))
    }

    func beginRename(_ node: FileNode) {
        guard let window = view.window else { return }
        select([node])
        RenamePrompt.run(node, in: window, host: host)
    }

    private func requestThumbnail(for node: FileNode) {
        thumbnails.request(node, device: contents?.device, size: 128) { [weak self] node in
            guard let self, let path = self.indexPath(of: node), let item = self.collectionView.item(at: path) as? IconItem else { return }
            item.imageView?.image = node.displayIcon
        }
    }
}

// MARK: - 数据源 / 代理

extension IconViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func numberOfSections(in collectionView: NSCollectionView) -> Int { groups.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        groups.indices.contains(section) ? groups[section].nodes.count : 0
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: IconItem.identifier, for: indexPath)
        guard let iconItem = item as? IconItem, let node = node(at: indexPath) else { return item }
        iconItem.textField?.stringValue = node.name
        iconItem.textField?.toolTip = node.name
        iconItem.imageView?.image = node.displayIcon
        requestThumbnail(for: node)
        return iconItem
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: SectionHeaderView.identifier, for: indexPath)
        if let header = header as? SectionHeaderView, groups.indices.contains(indexPath.section) {
            header.configure(title: groups[indexPath.section].title, count: groups[indexPath.section].nodes.count)
        }
        return header
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { host?.selectionDidChange() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { host?.selectionDidChange() }

    // 拖出
    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool { true }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        node(at: indexPath).flatMap { host?.pasteboardWriter(for: $0) }
    }

    // 拖入：放到文件夹图标上 = 放进那个文件夹，否则放到当前文件夹
    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        if dropOperation.pointee == .on, let folder = node(at: proposedIndexPath.pointee as IndexPath), folder.isFolder {
            return host?.validateDrop(draggingInfo, onto: folder) ?? []
        }
        dropOperation.pointee = .before
        if contents?.searchQuery != nil { return [] }
        return host?.validateDrop(draggingInfo, onto: nil) ?? []
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath,
                        dropOperation: NSCollectionView.DropOperation) -> Bool {
        let folder = node(at: indexPath)
        let target = dropOperation == .on && folder?.isFolder == true ? folder : nil
        return host?.acceptDrop(draggingInfo, onto: target) ?? false
    }
}

extension IconViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        host?.populateContextMenu(menu, for: actionNodes)
    }
}

// MARK: - 视图

/// 记录双击与右键点到的项目，处理键盘
@MainActor
final class IconCollectionView: NSCollectionView {
    var onDoubleClick: ((IndexPath) -> Void)?
    private(set) var clickedIndexPath: IndexPath?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            onDoubleClick?(path)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        clickedIndexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        return super.menu(for: event)
    }

    override func keyDown(with event: NSEvent) {
        if FileViewKeys.handle(event, from: self) { return }
        super.keyDown(with: event)
    }
}

/// 图标视图的分组标题：组名 + 项目数，下面一条细线（Finder 图标视图的样式）
@MainActor
final class SectionHeaderView: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("SectionHeaderView")

    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        countLabel.textColor = .secondaryLabelColor
        let line = NSBox.separator()
        for v in [titleLabel, countLabel, line] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.bottomAnchor.constraint(equalTo: line.topAnchor, constant: -5),
            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            countLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, count: Int) {
        titleLabel.stringValue = title
        countLabel.stringValue = String(localized: "\(count) 项")
    }
}

/// 一个图标格子：图标在上，名字（最多两行）在下；选中时图标加底色、名字高亮
@MainActor
final class IconItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("IconItem")

    private let iconBackground = NSView()

    override func loadView() {
        let root = NSView()
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        let text = NSTextField(wrappingLabelWithString: "")
        text.alignment = .center
        text.maximumNumberOfLines = 2
        text.lineBreakMode = .byTruncatingMiddle
        text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        iconBackground.wantsLayer = true
        iconBackground.layer?.cornerRadius = 6
        text.wantsLayer = true
        text.layer?.cornerRadius = 4
        for v in [iconBackground, image, text] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            image.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            image.widthAnchor.constraint(equalToConstant: 64),
            image.heightAnchor.constraint(equalToConstant: 64),
            iconBackground.centerXAnchor.constraint(equalTo: image.centerXAnchor),
            iconBackground.centerYAnchor.constraint(equalTo: image.centerYAnchor),
            iconBackground.widthAnchor.constraint(equalToConstant: 74),
            iconBackground.heightAnchor.constraint(equalToConstant: 74),
            text.topAnchor.constraint(equalTo: image.bottomAnchor, constant: 4),
            text.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            text.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -4),
        ])
        view = root
        imageView = image
        textField = text
    }

    override var isSelected: Bool { didSet { updateSelection() } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { updateSelection() } }

    private func updateSelection() {
        let on = isSelected || highlightState == .forSelection || highlightState == .asDropTarget
        iconBackground.layer?.backgroundColor = on ? NSColor.unemphasizedSelectedContentBackgroundColor.cgColor : nil
        textField?.layer?.backgroundColor = on ? NSColor.selectedContentBackgroundColor.cgColor : nil
        textField?.textColor = on ? .alternateSelectedControlTextColor : .labelColor
    }
}
