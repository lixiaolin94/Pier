import AppKit
import PierKit

/// 应用级的共享服务
@MainActor
enum Services {
    /// 传输队列。未完成的任务保存在 Application Support，重启后恢复。
    static let transfers = TransferQueue(storeURL: AppPaths.support.appendingPathComponent("transfers.json")) { persistentID in
        guard let device = DeviceManager.shared.readyDevice(persistentID: persistentID), let session = device.session else { return nil }
        return .init(session: session, storages: device.storages, name: device.name)
    }
}

enum AppPaths {
    /// ~/Library/Application Support/Pier
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Pier", isDirectory: true)
    }()

    /// ~/Library/Caches/work.xiaolin.Pier
    static let caches: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "work.xiaolin.Pier", isDirectory: true)
    }()

    /// 文件名里不能出现的字符替换掉，用作缓存目录名
    static func safeComponent(_ s: String) -> String {
        String(s.map { "/:\\".contains($0) ? "_" : $0 })
    }
}

extension MTPDevice {
    /// 当前位置是不是这台设备
    func owns(_ location: BrowserLocation?) -> Bool { location?.deviceID == id }
}
