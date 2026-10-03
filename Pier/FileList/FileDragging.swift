import AppKit
import PierKit
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// 设备上项目的引用（窗口内拖拽移动用）
    static let pierItem = NSPasteboard.PasteboardType("work.xiaolin.Pier.item")
}

/// 拖拽 / 拷贝时携带的设备上项目
struct RemoteItemReference: Codable, Hashable {
    /// 本次连接内的设备 ID（`MTPDevice.id`）
    var deviceID: String
    /// 跨连接的设备标识（`MTPDevice.persistentID`）
    var persistentID: String
    var deviceName: String
    var storageID: UInt32
    var handle: UInt32
    var name: String
    var isFolder: Bool
    var size: UInt64
    /// 所在文件夹的路径
    var folderPath: [MTPPathComponent]

    var object: MTPObject {
        MTPObject(handle: handle, storageID: storageID, parent: folderPath.last?.handle ?? storageID, name: name,
                  format: isFolder ? .association : .undefined, size: size, modified: nil)
    }

    @MainActor init(node: FileNode, device: MTPDevice) {
        deviceID = device.id
        persistentID = device.persistentID
        deviceName = device.name
        storageID = node.object.storageID
        handle = node.object.handle
        name = node.name
        isFolder = node.isFolder
        size = node.object.size
        folderPath = node.folderPath
    }

    /// 从拖拽 / 剪贴板里读出所有设备上项目
    static func read(from pasteboard: NSPasteboard) -> [RemoteItemReference] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            item.data(forType: .pierItem).flatMap { try? JSONDecoder().decode(RemoteItemReference.self, from: $0) }
        }
    }
}

/// 设备上一个项目的文件承诺：拖到 Finder（或在 Finder 里粘贴）时才真正开始下载。
/// 同时带上 `.pierItem`，拖回 Pier 窗口内时变成移动。
final class RemoteFilePromiseProvider: NSFilePromiseProvider {
    let reference: RemoteItemReference

    init(reference: RemoteItemReference) {
        self.reference = reference
        let type = reference.isFolder ? UTType.folder : (UTType(filenameExtension: (reference.name as NSString).pathExtension) ?? .data)
        super.init()
        fileType = type.identifier
        delegate = FilePromiseCoordinator.shared
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.pierItem]
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == .pierItem ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .pierItem { return try? JSONEncoder().encode(reference) }
        return super.pasteboardPropertyList(forType: type)
    }
}

/// 兑现文件承诺：把下载交给传输队列，下载结束时通知 Finder
final class FilePromiseCoordinator: NSObject, NSFilePromiseProviderDelegate, Sendable {
    static let shared = FilePromiseCoordinator()

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (provider as? RemoteFilePromiseProvider)?.reference.name ?? "Untitled"
    }

    /// 在主线程上兑现，方便直接操作传输队列
    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { .main }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        let done = UncheckedBox(completionHandler)
        guard let reference = (provider as? RemoteFilePromiseProvider)?.reference else {
            completionHandler(CocoaError(.fileWriteUnknown))
            return
        }
        MainActor.assumeIsolated {
            guard let device = DeviceManager.shared.readyDevice(persistentID: reference.persistentID) else {
                done.value(TransferError.deviceUnavailable)
                return
            }
            // Finder 给的位置已有同名项目时不覆盖，改用"名称 2"
            let target = FileOperations.uniqueLocalURL(url)
            let transfer = Services.transfers.download(reference.object, from: reference.folderPath, deviceID: device.persistentID,
                                                       deviceName: device.name, to: target)
            transfer.onFinish { t in
                switch t.state {
                case .completed: done.value(nil)
                case .cancelled: done.value(CocoaError(.userCancelled))
                case let .failed(message): done.value(NSError(domain: "work.xiaolin.Pier", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
                default: done.value(nil)
                }
            }
        }
    }
}

/// 把非 Sendable 的值带进主线程闭包（调用方保证只在主线程上使用）
final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
