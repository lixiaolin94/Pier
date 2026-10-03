import AppKit
import PierKit
import QuickLookThumbnailing

/// 设备上文件的本地缓存副本：Quick Look、用默认 app 打开、缩略图都先下载到这里。
/// 句柄只在本次会话有效，缓存目录在每次启动时清空。
@MainActor
final class LocalCopies {
    static let shared = LocalCopies()

    private let root = AppPaths.caches.appendingPathComponent("Preview", isDirectory: true)
    private var tasks: [URL: Task<URL, Error>] = [:]

    private init() {
        try? FileManager.default.removeItem(at: root)
    }

    /// 缓存位置：按设备、存储、句柄、大小分目录，文件名保持原名（Quick Look 和其他 app 靠扩展名识别类型）
    func url(for object: MTPObject, on device: MTPDevice) -> URL {
        root.appendingPathComponent(AppPaths.safeComponent(device.persistentID), isDirectory: true)
            .appendingPathComponent("\(object.storageID)-\(object.handle)-\(object.size)", isDirectory: true)
            .appendingPathComponent(AppPaths.safeComponent(object.name))
    }

    func cachedURL(for object: MTPObject, on device: MTPDevice) -> URL? {
        let url = url(for: object, on: device)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 取得本地副本，没有就下载。同一个文件的并发请求共用一次下载。
    func fetch(_ object: MTPObject, on device: MTPDevice, priority: RequestPriority) async throws -> URL {
        let url = url(for: object, on: device)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        if let running = tasks[url] { return try await running.value }
        guard let session = device.session else { throw TransferError.deviceUnavailable }
        let task = Task<URL, Error> {
            let temp = url.deletingLastPathComponent().appendingPathComponent(".partial")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await session.download(object.handle, size: object.size, into: temp, progress: TransferProgress(), priority: priority)
            try FileManager.default.moveItem(at: temp, to: url)
            return url
        }
        tasks[url] = task
        defer { tasks[url] = nil }
        return try await task.value
    }

    // MARK: 缩略图

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "bmp", "tif", "tiff", "dng"]
    /// 超过这个大小的图片不生成缩略图（要整个下载下来）
    private static let thumbnailSizeLimit: UInt64 = 24 << 20

    func canThumbnail(_ object: MTPObject) -> Bool {
        !object.isFolder && object.size > 0 && object.size <= Self.thumbnailSizeLimit
            && Self.imageExtensions.contains((object.name as NSString).pathExtension.lowercased())
    }

    /// 后台低优先级下载图片并生成缩略图
    func thumbnail(for object: MTPObject, on device: MTPDevice, size: CGSize) async -> NSImage? {
        guard canThumbnail(object), let url = try? await fetch(object, on: device, priority: .background) else { return nil }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        return image
    }
}
