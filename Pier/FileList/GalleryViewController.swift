import AppKit
import PierKit
import Quartz

/// 画廊视图（Finder 式）：上面是选中项目的大预览，下面一排缩略图。和 Finder 一样不分组。
///
/// MTP 不能只读文件的一部分来预览，所以预览要先把文件下载到本机缓存（和 Quick Look 共用 LocalCopies）。
/// 太大的文件不自动下载，只显示大图标，按空格键仍可用 Quick Look 预览。
@MainActor
final class GalleryViewController: NSViewController, FileBrowsingView {
    weak var host: FileViewHost?

    /// 超过这个大小的文件不自动下载来预览（左右翻看时不能每次都等几十秒）
    static let autoPreviewLimit: UInt64 = 64 << 20

    private let strip = IconCollectionView()
    private let previewContainer = NSView()
    private var quickLookView: QLPreviewView?
    private let iconView = NSImageView()
    private let spinner = NSProgressIndicator()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let thumbnails = ThumbnailRequests()
    private var previewedNode: FileNode?

    private var contents: FolderContents? { host?.contents }
    private var nodes: [FileNode] { contents?.displayedNodes ?? [] }

    override func loadView() {
        // 下面的缩略图条
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: 64, height: 64)
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        layout.sectionInset = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        strip.collectionViewLayout = layout
        strip.isSelectable = true
        strip.allowsMultipleSelection = true
        strip.allowsEmptySelection = true
        strip.backgroundColors = [.clear]
        strip.dataSource = self
        strip.delegate = self
        strip.register(ThumbItem.self, forItemWithIdentifier: ThumbItem.identifier)
        strip.registerForDraggedTypes([.fileURL, .pierItem])
        strip.setDraggingSourceOperationMask(.copy, forLocal: false)
        strip.setDraggingSourceOperationMask([.move, .copy, .link], forLocal: true)
        strip.menu = NSMenu()
        strip.menu?.delegate = self
        strip.onDoubleClick = { [weak self] path in
            guard let self, path.item < self.nodes.count else { return }
            self.host?.open(self.nodes[path.item], inNewTab: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
        }
        let stripScroll = NSScrollView()
        stripScroll.documentView = strip
        stripScroll.hasHorizontalScroller = true
        stripScroll.autohidesScrollers = true
        stripScroll.drawsBackground = false

        // 上面的预览。大图标跟着预览区缩放：不能让它的固有尺寸反过来把整个内容区压扁
        iconView.imageScaling = .scaleProportionallyUpOrDown
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            iconView.setContentHuggingPriority(.init(1), for: orientation)
            iconView.setContentCompressionResistancePriority(.init(1), for: orientation)
        }
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center

        let root = NSView()
        for v in [previewContainer, iconView, spinner, nameLabel, detailLabel, stripScroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        let separator = NSBox.separator()
        separator.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(separator)

        NSLayoutConstraint.activate([
            previewContainer.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            previewContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            previewContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            previewContainer.bottomAnchor.constraint(equalTo: nameLabel.topAnchor, constant: -10),

            iconView.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalTo: iconView.heightAnchor),
            iconView.heightAnchor.constraint(equalTo: previewContainer.heightAnchor, multiplier: 0.6),
            iconView.heightAnchor.constraint(lessThanOrEqualToConstant: 256),
            spinner.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 8),

            nameLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            nameLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            nameLabel.bottomAnchor.constraint(equalTo: detailLabel.topAnchor, constant: -2),
            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            detailLabel.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -12),

            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: stripScroll.topAnchor),
            stripScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stripScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stripScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stripScroll.heightAnchor.constraint(equalToConstant: 100),
        ])
        view = root
        showPreview(for: nil)
    }

    // MARK: 预览

    private func updatePreview() {
        let node = selectedNodes.first
        guard node !== previewedNode else { return }
        showPreview(for: node)
    }

    private func showPreview(for node: FileNode?) {
        previewedNode = node
        spinner.stopAnimation(nil)
        guard let node else {
            setQuickLook(nil)
            iconView.image = nil
            nameLabel.stringValue = ""
            detailLabel.stringValue = nodes.isEmpty ? "" : String(localized: "选择一个项目以预览")
            return
        }
        nameLabel.stringValue = node.name
        detailLabel.stringValue = node.kindAndSize
        iconView.image = node.displayIcon

        guard !node.isFolder, let device = contents?.device else {
            setQuickLook(nil)
            return
        }
        if let url = LocalCopies.shared.cachedURL(for: node.object, on: device) {
            setQuickLook(url)
            return
        }
        setQuickLook(nil)
        guard node.object.size <= Self.autoPreviewLimit else {
            detailLabel.stringValue = node.kindAndSize + String(localized: " · 文件较大，按空格键预览")
            return
        }
        spinner.startAnimation(nil)
        let object = node.object
        Task { [weak self, weak node] in
            let url = try? await LocalCopies.shared.fetch(object, on: device, priority: .interactive)
            guard let self, let node, self.previewedNode === node else { return }
            self.spinner.stopAnimation(nil)
            if let url { self.setQuickLook(url) }
        }
    }

    /// 有本地副本时用 Quick Look 显示内容，否则显示大图标
    private func setQuickLook(_ url: URL?) {
        if let url {
            if quickLookView == nil, let ql = QLPreviewView(frame: previewContainer.bounds, style: .normal) {
                ql.autoresizingMask = [.width, .height]
                ql.shouldCloseWithWindow = false
                previewContainer.addSubview(ql)
                quickLookView = ql
            }
            quickLookView?.previewItem = url as NSURL
            quickLookView?.isHidden = false
            iconView.isHidden = true
        } else {
            quickLookView?.previewItem = nil
            quickLookView?.isHidden = true
            iconView.isHidden = false
        }
    }

    // MARK: FileBrowsingView

    func contentsDidChange(_ change: FolderContents.Change) {
        guard isViewLoaded, case .reload = change else { return }
        let selected = Set(selectedNodes.map(ObjectIdentifier.init))
        thumbnails.keep(only: nodes)
        strip.reloadData()
        var paths = Set(nodes.enumerated().filter { selected.contains(ObjectIdentifier($0.element)) }.map { IndexPath(item: $0.offset, section: 0) })
        // 画廊总要预览点什么：没有选择时选中第一个
        if paths.isEmpty, !nodes.isEmpty { paths = [IndexPath(item: 0, section: 0)] }
        strip.selectionIndexPaths = paths
        updatePreview()
        if nodes.isEmpty { showPreview(for: nil) }
    }

    var selectedNodes: [FileNode] {
        strip.selectionIndexPaths.sorted().compactMap { $0.item < nodes.count ? nodes[$0.item] : nil }
    }

    var actionNodes: [FileNode] {
        if let clicked = strip.clickedIndexPath?.item, clicked < nodes.count,
           !strip.selectionIndexPaths.contains(IndexPath(item: clicked, section: 0)) {
            return [nodes[clicked]]
        }
        return selectedNodes
    }

    func select(_ selection: [FileNode]) {
        let ids = Set(selection.map(ObjectIdentifier.init))
        let paths = Set(nodes.enumerated().filter { ids.contains(ObjectIdentifier($0.element)) }.map { IndexPath(item: $0.offset, section: 0) })
        strip.selectionIndexPaths = paths
        if !paths.isEmpty { strip.scrollToItems(at: paths, scrollPosition: .centeredHorizontally) }
        updatePreview()
        host?.selectionDidChange()
    }

    func beginRename(_ node: FileNode) {
        guard let window = view.window else { return }
        select([node])
        RenamePrompt.run(node, in: window, host: host)
    }

    func focus() { view.window?.makeFirstResponder(strip) }

    func screenRect(for node: FileNode) -> NSRect? {
        guard let window = view.window else { return nil }
        if node === previewedNode {
            let target: NSView = quickLookView?.isHidden == false ? previewContainer : iconView
            return window.convertToScreen(target.convert(target.bounds, to: nil))
        }
        return nil
    }
}

// MARK: - 缩略图条

extension GalleryViewController: NSCollectionViewDataSource, NSCollectionViewDelegate, NSMenuDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { nodes.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: ThumbItem.identifier, for: indexPath)
        guard indexPath.item < nodes.count else { return item }
        let node = nodes[indexPath.item]
        item.imageView?.image = node.displayIcon
        item.view.toolTip = node.name
        thumbnails.request(node, device: contents?.device, size: 128) { [weak self] node in
            guard let self, let index = self.nodes.firstIndex(of: node) else { return }
            self.strip.item(at: IndexPath(item: index, section: 0))?.imageView?.image = node.displayIcon
            if self.previewedNode === node && self.quickLookView?.isHidden != false { self.iconView.image = node.displayIcon }
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        updatePreview()
        host?.selectionDidChange()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        updatePreview()
        host?.selectionDidChange()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        host?.populateContextMenu(menu, for: actionNodes)
    }

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool { true }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard indexPath.item < nodes.count else { return nil }
        return host?.pasteboardWriter(for: nodes[indexPath.item])
    }

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

/// 缩略图条里的一格：只有图，选中时加圆角强调色描边
@MainActor
final class ThumbItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ThumbItem")

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 6
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(image)
        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            image.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),
            image.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            image.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
        ])
        view = root
        imageView = image
    }

    override var isSelected: Bool { didSet { updateSelection() } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { updateSelection() } }

    private func updateSelection() {
        let on = isSelected || highlightState == .forSelection || highlightState == .asDropTarget
        view.layer?.backgroundColor = on ? NSColor.unemphasizedSelectedContentBackgroundColor.cgColor : nil
        view.layer?.borderWidth = on ? 2 : 0
        view.layer?.borderColor = on ? NSColor.controlAccentColor.cgColor : nil
    }
}
