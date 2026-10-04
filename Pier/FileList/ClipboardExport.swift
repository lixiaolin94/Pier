import AppKit
import PierKit

/// ⌘C：Finder 粘贴时不接受剪贴板上的文件承诺（0.1.2 实测，拖拽才接受），
/// 所以先把项目下载到本机缓存，下载完再把文件 URL 放进剪贴板。
///
/// - 下载走传输队列：有进度、能取消、支持文件夹。
/// - 下载期间剪贴板里先放 `.pierItem`，在 Pier 里粘贴时能认出来并提示稍等。
/// - 文件 URL 和 `.pierItem` 一起放：在 Finder 里粘贴得到文件；在 Pier 里粘贴 = 把缓存里的副本上传，即设备内复制。
/// - 用户在下载完成前又拷贝了别的东西（changeCount 变了），就不再覆盖剪贴板。
@MainActor
final class ClipboardExport {
    static let shared = ClipboardExport()

    /// 超过这个大小先确认：大文件建议直接拖到 Finder 或用「下载到…」，不必多占一份缓存
    static let confirmThreshold: UInt64 = 1 << 30

    private let root = AppPaths.caches.appendingPathComponent("Clipboard", isDirectory: true)
    private var current: (id: UUID, transfers: [Transfer])?

    private init() {
        try? FileManager.default.removeItem(at: root)
    }

    /// 是否正在为剪贴板准备内容
    var isPreparing: Bool { current != nil }

    /// - Parameter completion: 成功时 nil，失败时是原因；被新的拷贝或其他剪贴板内容取代时不回调
    func copy(_ items: [RemoteItemReference], completion: @escaping @MainActor (String?) -> Void) {
        guard !items.isEmpty else { return }
        cancelCurrent()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(items.map(Self.referenceItem))
        let changeCount = pasteboard.changeCount

        let id = UUID()
        let dir = root.appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            completion(TransferQueue.message(for: error))
            return
        }
        var transfers: [Transfer] = []
        for item in items {
            guard let device = DeviceManager.shared.readyDevice(persistentID: item.persistentID) else { continue }
            transfers.append(Services.transfers.download(item.object, from: item.folderPath, deviceID: device.persistentID,
                                                        deviceName: device.name, to: dir.appendingPathComponent(item.name)))
        }
        guard !transfers.isEmpty else {
            completion(TransferError.deviceUnavailable.errorDescription)
            return
        }
        current = (id, transfers)

        var remaining = transfers.count
        for t in transfers {
            t.onFinish { [weak self] _ in
                remaining -= 1
                guard remaining == 0, let self, self.current?.id == id else { return }
                self.current = nil
                self.finish(items: items, transfers: transfers, changeCount: changeCount, completion: completion)
            }
        }
    }

    private func finish(items: [RemoteItemReference], transfers: [Transfer], changeCount: Int, completion: @MainActor (String?) -> Void) {
        if let failed = transfers.first(where: { $0.state != .completed }) {
            if case let .failed(message) = failed.state { completion(message) }
            return   // 取消了就不提示
        }
        let pasteboard = NSPasteboard.general
        // 用户已经拷贝了别的东西
        guard pasteboard.changeCount == changeCount else { return }
        pasteboard.clearContents()
        let entries = zip(items, transfers).map { item, transfer -> NSPasteboardItem in
            let entry = Self.referenceItem(item)
            entry.setString(transfer.localURL.absoluteString, forType: .fileURL)
            return entry
        }
        pasteboard.writeObjects(entries)
        completion(nil)
    }

    private func cancelCurrent() {
        guard let current else { return }
        self.current = nil
        current.transfers.filter { !$0.state.isFinished }.forEach(Services.transfers.cancel)
    }

    private static func referenceItem(_ reference: RemoteItemReference) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        if let data = try? JSONEncoder().encode(reference) { item.setData(data, forType: .pierItem) }
        return item
    }
}
