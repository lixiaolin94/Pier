import AppKit
import PierKit

/// 列表 / 图标视图中的一个节点。视图靠对象身份追踪展开与选中，所以用类。
@MainActor
final class FileNode: NSObject {
    var object: MTPObject
    /// 所在文件夹的路径（从存储根目录开始；根目录下的项目为空数组）
    let folderPath: [MTPPathComponent]
    /// 在列表视图里展开的父节点（顶层节点为 nil）
    weak var parent: FileNode?
    /// 子节点；nil 表示还没读取（仅文件夹）
    var children: [FileNode]?
    var loadTask: Task<Void, Never>?
    var thumbnail: NSImage?

    init(_ object: MTPObject, in folderPath: [MTPPathComponent], parent: FileNode? = nil) {
        self.object = object
        self.folderPath = folderPath
        self.parent = parent
    }

    var name: String { object.name }
    var isFolder: Bool { object.isFolder }
    var component: MTPPathComponent { MTPPathComponent(handle: object.handle, name: object.name) }
    /// 文件夹自身的路径
    var path: [MTPPathComponent] { folderPath + [component] }
    /// 所在文件夹的句柄
    var parentHandle: UInt32 { folderPath.last?.handle ?? PTPHandle.root }
}

/// 一个浏览位置的内容：边读边显示、排序过滤、展开的子文件夹、递归搜索结果，以及操作之后的本地更新。
///
/// 设备侧的目录缓存靠不住（DBI 移动后不刷新、重复 handle、残缺名字），这里是界面唯一的数据来源：
/// 新建、改名、删除、移动、上传之后都直接改这里，不依赖重新枚举。
@MainActor
final class FolderContents: NSObject {
    enum Change {
        /// 内容变了，需要重新加载视图
        case reload
        /// 只有加载状态、提示文字变了
        case status
        /// 某个展开的文件夹读完了子项
        case children(FileNode)
    }

    var onChange: ((Change) -> Void)?

    /// 和 Finder 一样默认隐藏以 "." 开头的项目（如 macOS 写到 SD 卡上的 ._ 文件），⌘⇧. 切换
    static let hiddenFilesKey = "ShowHiddenFiles"
    static let hiddenFilesDidChange = Notification.Name("work.xiaolin.Pier.hiddenFilesDidChange")
    static var showsHiddenFiles: Bool { UserDefaults.standard.bool(forKey: hiddenFilesKey) }

    private func visible(_ nodes: [FileNode]) -> [FileNode] {
        Self.showsHiddenFiles ? nodes : nodes.filter { !$0.name.hasPrefix(".") }
    }

    private(set) var location: BrowserLocation?
    private(set) var device: MTPDevice?
    var session: MTPSession? { device?.session }
    var quirks: DeviceQuirks? { device?.quirks }
    var storage: MTPStorage? { location?.resolved?.storage }

    private(set) var rootNodes: [FileNode] = []
    private(set) var displayedNodes: [FileNode] = []
    private(set) var isLoading = false
    private(set) var message: String?
    /// 不为 nil 时处于递归搜索模式，rootNodes 是搜索结果
    private(set) var searchQuery: String?

    var filterText = "" {
        didSet { if filterText != oldValue { refresh() } }
    }

    var sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)] {
        didSet {
            resortLoadedChildren(rootNodes)
            refresh()
        }
    }

    private var loadTask: Task<Void, Never>?

    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(deviceEvent(_:)), name: DeviceManager.deviceEvent, object: nil)
        center.addObserver(self, selector: #selector(objectsAdded(_:)), name: ModelEvents.objectsAdded, object: nil)
        center.addObserver(self, selector: #selector(objectsRemoved(_:)), name: ModelEvents.objectsRemoved, object: nil)
        center.addObserver(self, selector: #selector(objectChanged(_:)), name: ModelEvents.objectChanged, object: nil)
        center.addObserver(self, selector: #selector(hiddenFilesDidChange(_:)), name: Self.hiddenFilesDidChange, object: nil)
    }

    /// 展开的子文件夹里已经按旧设置过滤过，重新读一遍最省事
    @objc private func hiddenFilesDidChange(_ note: Notification) {
        if searchQuery == nil { reload() } else { refresh() }
    }

    @objc private func deviceEvent(_ note: Notification) {
        guard let device = note.userInfo?["device"] as? MTPDevice, let event = note.userInfo?["event"] as? PTPEvent else { return }
        handle(event, from: device)
    }

    @objc private func objectsAdded(_ note: Notification) {
        guard note.userInfo?["deviceID"] as? String == device?.id, let objects = note.userInfo?["objects"] as? [MTPObject] else { return }
        objects.forEach(place)
    }

    @objc private func objectsRemoved(_ note: Notification) {
        guard note.userInfo?["deviceID"] as? String == device?.id, let handles = note.userInfo?["handles"] as? Set<UInt32> else { return }
        remove(handles: handles)
    }

    @objc private func objectChanged(_ note: Notification) {
        guard note.userInfo?["deviceID"] as? String == device?.id, let object = note.userInfo?["object"] as? MTPObject,
              let node = node(handle: object.handle), node.object != object else { return }
        rename(node, to: object.name)
    }

    /// 把一个新出现的对象放到它所在的位置（当前文件夹或某个展开的子文件夹）；不在视野内就忽略
    private func place(_ object: MTPObject) {
        guard let location, object.storageID == location.storageID, searchQuery == nil else { return }
        if isInCurrentFolder(object) {
            insert(object, in: nil)
        } else if let parent = folderNode(handle: object.parent) {
            insert(object, in: parent)
        }
    }

    // MARK: 加载

    /// 显示某个位置的内容。切换位置会立即取消上一次的读取。
    func load(_ location: BrowserLocation?) {
        cancelAll()
        self.location = location
        searchQuery = nil
        rootNodes = []
        message = nil
        device = location?.resolved?.device
        refresh()

        guard let location, let session else {
            setLoading(false)
            return
        }
        setLoading(true)
        loadTask = Task { [weak self] in
            do {
                for try await batch in session.listChildren(storage: location.storageID, parent: location.folderHandle) {
                    guard let self, !Task.isCancelled else { return }
                    self.appendRoot(MoveLedger.apply(batch, folder: location.folderHandle, deviceID: location.deviceID, final: false), in: location.path)
                }
                guard let self, !Task.isCancelled else { return }
                self.appendRoot(MoveLedger.apply([], folder: location.folderHandle, deviceID: location.deviceID, final: true), in: location.path)
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

    func reload() { load(location) }

    private func cancelAll() {
        loadTask?.cancel()
        loadTask = nil
        func cancel(_ node: FileNode) {
            node.loadTask?.cancel()
            node.children?.forEach(cancel)
        }
        rootNodes.forEach(cancel)
    }

    private func appendRoot(_ objects: [MTPObject], in folder: [MTPPathComponent]) {
        var names = Set(rootNodes.map(\.name))
        let fresh = objects.filter { names.insert($0.name).inserted }   // DBI 的重复 handle
        guard !fresh.isEmpty else { return }
        rootNodes += fresh.map { FileNode($0, in: folder) }
        message = nil
        refresh()
    }

    /// 列表视图展开文件夹时按需读取子项
    func loadChildren(of node: FileNode) {
        guard node.isFolder, node.children == nil, node.loadTask == nil, let session, let location else { return }
        node.loadTask = Task { [weak self, weak node] in
            let handle = node?.object.handle ?? 0
            let listed = (try? await session.children(storage: location.storageID, parent: handle, priority: .interactive)) ?? []
            let objects = MoveLedger.apply(listed, folder: handle, deviceID: location.deviceID, final: true)
            guard let self, let node, !Task.isCancelled else { return }
            node.children = self.sorted(self.visible(objects.map { FileNode($0, in: node.path, parent: node) }))
            node.loadTask = nil
            self.onChange?(.children(node))
        }
    }

    private func setLoading(_ loading: Bool) {
        isLoading = loading
        onChange?(.status)
    }

    private func setMessage(_ text: String?) {
        message = text
        onChange?(.status)
    }

    // MARK: 递归搜索

    /// 从当前文件夹开始递归搜索整个子树
    func search(_ query: String) {
        guard let location, let session, !query.isEmpty else { return }
        cancelAll()
        searchQuery = query
        rootNodes = []
        message = nil
        refresh()
        setLoading(true)
        loadTask = Task { [weak self] in
            do {
                for try await hits in session.search(storage: location.storageID, under: location.folderHandle, matching: query) {
                    guard let self, !Task.isCancelled else { return }
                    self.rootNodes += hits.map { FileNode($0.object, in: location.path + $0.folderPath) }
                    self.refresh()
                }
                guard let self, !Task.isCancelled else { return }
                self.setLoading(false)
                if self.rootNodes.isEmpty { self.setMessage(String(localized: "没有找到“\(query)”")) }
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.setLoading(false)
                self.setMessage(String(localized: "搜索失败：\(String(describing: error))"))
            }
        }
    }

    /// 退出搜索，回到文件夹内容
    func endSearch() {
        guard searchQuery != nil else { return }
        load(location)
    }

    // MARK: 排序与过滤

    func refresh() {
        var nodes = visible(rootNodes)
        if !filterText.isEmpty && searchQuery == nil {
            nodes = nodes.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
        }
        displayedNodes = sorted(nodes)
        onChange?(.reload)
    }

    func sorted(_ nodes: [FileNode]) -> [FileNode] {
        guard let descriptor = sortDescriptors.first, let key = descriptor.key else { return nodes }
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

    private func resortLoadedChildren(_ nodes: [FileNode]) {
        for node in nodes {
            guard let children = node.children else { continue }
            node.children = sorted(children)
            resortLoadedChildren(children)
        }
    }

    var hasDates: Bool { rootNodes.contains { $0.object.modified != nil } }

    // MARK: 本地更新

    /// 同一文件夹里已有的名字（用于新建、改名、上传前的预检）
    func siblingNames(in parent: FileNode?) -> [String]? {
        if let parent { return parent.children?.map(\.name) }
        return searchQuery == nil ? rootNodes.map(\.name) : nil
    }

    /// 某个句柄对应的、已经读出来的文件夹节点（nil 表示当前文件夹本身）
    func folderNode(handle: UInt32) -> FileNode? {
        func find(_ nodes: [FileNode]) -> FileNode? {
            for n in nodes {
                if n.isFolder && n.object.handle == handle { return n }
                if let c = n.children, let f = find(c) { return f }
            }
            return nil
        }
        return find(rootNodes)
    }

    /// 把新对象加进去。`parent` 为 nil 表示当前文件夹。返回新节点（已存在同名则返回已有的）。
    @discardableResult
    func insert(_ object: MTPObject, in parent: FileNode?) -> FileNode? {
        if let parent {
            guard var children = parent.children else { return nil }   // 还没读过，展开时自然会读到
            if object.name.hasPrefix(".") && !Self.showsHiddenFiles { return nil }
            if let existing = children.first(where: { $0.name == object.name }) { return existing }
            let node = FileNode(object, in: parent.path, parent: parent)
            children.append(node)
            parent.children = sorted(children)
            onChange?(.children(parent))
            return node
        }
        guard searchQuery == nil, let location else { return nil }
        if let existing = rootNodes.first(where: { $0.name == object.name || $0.object.handle == object.handle }) {
            existing.object = object
            refresh()
            return existing
        }
        let node = FileNode(object, in: location.path)
        rootNodes.append(node)
        message = nil
        refresh()
        onChange?(.status)
        return node
    }

    /// 删除（或移走）之后，把节点从模型里拿掉
    func remove(handles: Set<UInt32>) {
        guard !handles.isEmpty else { return }
        func prune(_ nodes: [FileNode]) -> [FileNode] {
            nodes.filter { !handles.contains($0.object.handle) }.map { node in
                if let c = node.children { node.children = prune(c) }
                return node
            }
        }
        rootNodes = prune(rootNodes)
        refresh()
        if rootNodes.isEmpty && !isLoading && searchQuery == nil { setMessage(String(localized: "文件夹为空")) }
    }

    func rename(_ node: FileNode, to name: String) {
        node.object.name = name
        if let parent = node.parent, let children = parent.children {
            parent.children = sorted(children)
            onChange?(.children(parent))
        }
        refresh()
    }

    // MARK: 设备事件

    private func handle(_ event: PTPEvent, from device: MTPDevice) {
        guard device === self.device, let location, let session, let handle = event.parameters.first else { return }
        switch event.code {
        case .objectAdded, .objectInfoChanged:
            Task { [weak self] in
                guard let object = try? await session.object(handle, priority: .interactive), let self,
                      self.location == location, object.storageID == location.storageID else { return }
                if event.code == .objectInfoChanged, let node = self.node(handle: handle) {
                    node.object = object
                    self.refresh()
                    return
                }
                self.place(object)
            }
        case .objectRemoved:
            remove(handles: [handle])
        default:
            break
        }
    }

    private func node(handle: UInt32) -> FileNode? {
        func find(_ nodes: [FileNode]) -> FileNode? {
            for n in nodes {
                if n.object.handle == handle { return n }
                if let c = n.children, let f = find(c) { return f }
            }
            return nil
        }
        return find(rootNodes)
    }

    /// 对象是否直接位于当前文件夹（根目录对象的 parent 各设备填法不同：0、0xFFFFFFFF 或存储 ID）
    func isInCurrentFolder(_ object: MTPObject) -> Bool {
        guard let location else { return false }
        if location.path.isEmpty {
            return object.parent == 0 || object.parent == PTPHandle.root || object.parent == location.storageID
        }
        return object.parent == location.folderHandle
    }
}
