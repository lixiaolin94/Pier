import AppKit
import PierKit

/// 图标视图：大图标网格，图片在后台低优先级生成缩略图
@MainActor
final class IconViewController: NSViewController, FileBrowsingView {
    weak var host: FileViewHost?

    private let collectionView = IconCollectionView()
    private let thumbnails = ThumbnailRequests()
    private var contents: FolderContents? { host?.contents }
    private var nodes: [FileNode] { contents?.displayedNodes ?? [] }

    override func loadView() {
        let layout = NSCollectionViewFlowLayout()
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
        collectionView.registerForDraggedTypes([.fileURL, .pierItem])
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)
        collectionView.setDraggingSourceOperationMask([.move, .copy, .link], forLocal: true)
        collectionView.menu = NSMenu()
        collectionView.menu?.delegate = self
        collectionView.onDoubleClick = { [weak self] index in
            guard let self, index < self.nodes.count else { return }
            self.host?.open(self.nodes[index], inNewTab: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
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
        let selected = Set(selectedNodes.map(ObjectIdentifier.init))
        // 换了文件夹：之前排队的缩略图不要了
        thumbnails.keep(only: nodes)
        collectionView.reloadData()
        let paths = nodes.enumerated().filter { selected.contains(ObjectIdentifier($0.element)) }.map { IndexPath(item: $0.offset, section: 0) }
        collectionView.selectionIndexPaths = Set(paths)
    }

    var selectedNodes: [FileNode] {
        collectionView.selectionIndexPaths.sorted().compactMap { $0.item < nodes.count ? nodes[$0.item] : nil }
    }

    var actionNodes: [FileNode] {
        if let clicked = collectionView.clickedIndex, clicked < nodes.count,
           !collectionView.selectionIndexPaths.contains(IndexPath(item: clicked, section: 0)) {
            return [nodes[clicked]]
        }
        return selectedNodes
    }

    func select(_ selection: [FileNode]) {
        let ids = Set(selection.map(ObjectIdentifier.init))
        let paths = Set(nodes.enumerated().filter { ids.contains(ObjectIdentifier($0.element)) }.map { IndexPath(item: $0.offset, section: 0) })
        collectionView.selectionIndexPaths = paths
        if !paths.isEmpty { collectionView.scrollToItems(at: paths, scrollPosition: .nearestHorizontalEdge) }
        host?.selectionDidChange()
    }

    func focus() { view.window?.makeFirstResponder(collectionView) }

    func screenRect(for node: FileNode) -> NSRect? {
        guard let index = nodes.firstIndex(of: node), let window = view.window,
              let item = collectionView.item(at: IndexPath(item: index, section: 0)) as? IconItem,
              let image = item.imageView else { return nil }
        return window.convertToScreen(image.convert(image.bounds, to: nil))
    }

    func beginRename(_ node: FileNode) {
        guard let window = view.window else { return }
        select([node])
        RenamePrompt.run(node, in: window, host: host)
    }

    private func requestThumbnail(for node: FileNode) {
        thumbnails.request(node, device: contents?.device, size: 128) { [weak self] node in
            guard let self, let index = self.nodes.firstIndex(of: node),
                  let item = self.collectionView.item(at: IndexPath(item: index, section: 0)) as? IconItem else { return }
            item.imageView?.image = node.displayIcon
        }
    }
}

// MARK: - 数据源 / 代理

extension IconViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { nodes.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: IconItem.identifier, for: indexPath)
        guard let iconItem = item as? IconItem, indexPath.item < nodes.count else { return item }
        let node = nodes[indexPath.item]
        iconItem.textField?.stringValue = node.name
        iconItem.textField?.toolTip = node.name
        iconItem.imageView?.image = node.displayIcon
        requestThumbnail(for: node)
        return iconItem
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { host?.selectionDidChange() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { host?.selectionDidChange() }

    // 拖出
    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool { true }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard indexPath.item < nodes.count else { return nil }
        return host?.pasteboardWriter(for: nodes[indexPath.item])
    }

    // 拖入：放到文件夹图标上 = 放进那个文件夹，否则放到当前文件夹
    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let index = proposedIndexPath.pointee.item
        if dropOperation.pointee == .on, index < nodes.count, nodes[index].isFolder {
            return host?.validateDrop(draggingInfo, onto: nodes[index]) ?? []
        }
        dropOperation.pointee = .before
        if contents?.searchQuery != nil { return [] }
        return host?.validateDrop(draggingInfo, onto: nil) ?? []
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath,
                        dropOperation: NSCollectionView.DropOperation) -> Bool {
        let target = dropOperation == .on && indexPath.item < nodes.count && nodes[indexPath.item].isFolder ? nodes[indexPath.item] : nil
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
    var onDoubleClick: ((Int) -> Void)?
    private(set) var clickedIndex: Int?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            onDoubleClick?(path.item)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        clickedIndex = indexPathForItem(at: convert(event.locationInWindow, from: nil))?.item
        return super.menu(for: event)
    }

    override func keyDown(with event: NSEvent) {
        if FileViewKeys.handle(event, from: self) { return }
        super.keyDown(with: event)
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
