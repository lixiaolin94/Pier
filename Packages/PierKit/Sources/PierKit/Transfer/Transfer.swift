import Foundation

/// 一个传输任务：用户发起的一个顶层项目（文件或文件夹）的下载或上传。
///
/// 文件夹在开始时展开成扁平的条目列表（先文件夹后内容），逐个完成并记录，
/// 所以暂停、断线、重启 app 后都能从没完成的条目继续。
@MainActor
public final class Transfer: Identifiable {
    public enum Direction: String, Codable, Sendable {
        case download, upload
    }

    public enum State: Equatable, Sendable {
        /// 排队中（同一台设备一次只跑一个任务）
        case waiting
        /// 正在统计要传的文件
        case preparing
        case running
        case paused
        /// 设备断开了，重新连接后自动继续
        case waitingForDevice
        case failed(String)
        case completed
        case cancelled

        /// 已经结束、不会再动的状态
        public var isFinished: Bool { self == .completed || self == .cancelled }
        public var isRunning: Bool { self == .preparing || self == .running }
        /// 还在进行或等着进行（退出 app 前要提醒）
        public var isPending: Bool { isRunning || self == .waiting || self == .waitingForDevice }
        public var isFailed: Bool { if case .failed = self { true } else { false } }
    }

    /// 展开后的一个条目
    struct Entry: Codable, Sendable {
        /// 相对路径，第一个元素是顶层项目在设备上的名字
        var path: [String]
        var isFolder: Bool
        var size: UInt64
        /// 设备上的句柄（下载：源对象；上传：新建的对象）。只在 `sessionID` 对应的会话内有效。
        var handle: UInt32?
        var done: Bool
    }

    public let id: UUID
    public let direction: Direction
    /// 设备的持久标识（`MTPDevice.persistentID`），重连后靠它找回设备
    public let deviceID: String
    public internal(set) var deviceName: String
    public let storageID: UInt32
    /// 设备上的名字：下载时是源对象的名字，上传时是目标名字（"保留两者"时可能和本地名字不同）
    public let remoteName: String
    /// 下载：源对象所在的文件夹；上传：目标文件夹。从存储根目录开始，空数组表示根目录。
    public internal(set) var remoteFolder: [MTPPathComponent]
    /// 下载：本地的最终位置；上传：本地源文件
    public let localURL: URL
    public let isFolder: Bool
    public let createdAt: Date

    public internal(set) var state: State = .waiting
    public let progress = TransferProgress()
    /// 最近的速度（字节/秒），运行时由队列定时更新
    public internal(set) var bytesPerSecond: Double = 0
    /// 因名字冲突等原因跳过的项目
    public internal(set) var skipped: [String] = []
    /// 上传完成后，设备上新建的顶层对象
    public internal(set) var createdObject: MTPObject?
    /// 下载完成后的本地位置（保留两者时可能和发起时不同）
    public var resultURL: URL { localURL }

    var remoteHandle: UInt32?
    var pendingReplace: Bool
    var hasStarted = false
    var entries: [Entry]?
    var sessionID: ObjectIdentifier?
    var task: Task<Void, Never>?
    var lastSample: (time: Date, bytes: UInt64)?
    var publishedProgress: Progress?
    var finishHandlers: [@MainActor (Transfer) -> Void] = []

    init(direction: Direction, deviceID: String, deviceName: String, storageID: UInt32, remoteName: String,
         remoteFolder: [MTPPathComponent], remoteHandle: UInt32?, localURL: URL, isFolder: Bool, replaceExisting: Bool) {
        id = UUID()
        self.direction = direction
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.storageID = storageID
        self.remoteName = remoteName
        self.remoteFolder = remoteFolder
        self.remoteHandle = remoteHandle
        self.localURL = localURL
        self.isFolder = isFolder
        pendingReplace = replaceExisting
        createdAt = Date()
    }

    /// 显示名
    public var name: String { direction == .download ? localURL.lastPathComponent : remoteName }

    /// 任务结束（完成、失败或取消）时回调；已经结束的话立即回调
    public func onFinish(_ handler: @escaping @MainActor (Transfer) -> Void) {
        if state.isFinished || state.isFailed {
            handler(self)
        } else {
            finishHandlers.append(handler)
        }
    }

    func fireFinish() {
        let handlers = finishHandlers
        finishHandlers = []
        handlers.forEach { $0(self) }
    }

    /// 预计剩余时间（秒），速度未知时为 nil
    public var remainingSeconds: Double? {
        guard bytesPerSecond > 1 else { return nil }
        let s = progress.snapshot
        return Double(s.totalBytes &- s.completedBytes) / bytesPerSecond
    }

    // MARK: 持久化

    struct Record: Codable {
        var id: UUID
        var direction: Direction
        var deviceID: String
        var deviceName: String
        var storageID: UInt32
        var remoteName: String
        var remoteFolder: [MTPPathComponent]
        var localURL: URL
        var isFolder: Bool
        var createdAt: Date
        var pendingReplace: Bool
        var hasStarted: Bool
        var entries: [Entry]?
        var failure: String?
    }

    var record: Record {
        var failure: String?
        if case let .failed(message) = state { failure = message }
        return Record(id: id, direction: direction, deviceID: deviceID, deviceName: deviceName, storageID: storageID,
                      remoteName: remoteName, remoteFolder: remoteFolder, localURL: localURL, isFolder: isFolder,
                      createdAt: createdAt, pendingReplace: pendingReplace, hasStarted: hasStarted,
                      entries: entries, failure: failure)
    }

    init(record r: Record) {
        id = r.id
        direction = r.direction
        deviceID = r.deviceID
        deviceName = r.deviceName
        storageID = r.storageID
        remoteName = r.remoteName
        remoteFolder = r.remoteFolder
        localURL = r.localURL
        isFolder = r.isFolder
        createdAt = r.createdAt
        pendingReplace = r.pendingReplace
        hasStarted = r.hasStarted
        entries = r.entries
        // 句柄属于上一次会话，不再可信；重新开始时会按路径重新定位
        sessionID = nil
        state = r.failure.map(State.failed) ?? .paused
        recomputeProgress()
    }

    /// 按已完成的条目重算进度（续传前调用；正在传的文件由引擎从断点处补上）
    func recomputeProgress() {
        guard let entries else { return }
        let files = entries.filter { !$0.isFolder }
        progress.setTotals(bytes: files.reduce(0) { $0 + $1.size }, files: files.count)
        let done = files.filter(\.done)
        progress.reset(completedBytes: done.reduce(0) { $0 + $1.size }, completedFiles: done.count)
    }
}
