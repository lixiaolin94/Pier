import Foundation
import PierKit

/// 一个浏览位置：哪台设备、哪个存储、哪个文件夹
struct BrowserLocation: Equatable {
    typealias Folder = MTPPathComponent

    /// 本次连接内的设备 ID（`MTPDevice.id`）
    var deviceID: String
    var storageID: UInt32
    /// 从存储根目录到当前文件夹的路径；空数组表示存储根目录
    var path: [Folder] = []

    /// 当前文件夹的句柄（根目录为 0xFFFFFFFF）
    var folderHandle: UInt32 { path.last?.handle ?? PTPHandle.root }

    func appending(_ folder: Folder) -> BrowserLocation {
        var l = self
        l.path.append(folder)
        return l
    }

    /// 上层文件夹；已在存储根目录时为 nil
    var parent: BrowserLocation? {
        guard !path.isEmpty else { return nil }
        var l = self
        l.path.removeLast()
        return l
    }
}

extension BrowserLocation {
    /// 当前位置对应的设备与存储（设备已断开时为 nil）
    @MainActor var resolved: (device: MTPDevice, storage: MTPStorage)? {
        guard let device = DeviceManager.shared.device(withID: deviceID),
              let storage = device.storages.first(where: { $0.id == storageID }) else { return nil }
        return (device, storage)
    }

    /// 窗口 / tab 标题：当前文件夹名，根目录时用存储名
    @MainActor var title: String {
        if let last = path.last { return last.name }
        return resolved?.storage.displayName ?? "Pier"
    }

    /// 可以跨连接保存的形式（设备用持久标识，路径用名字）
    @MainActor var stored: StoredLocation? {
        guard let device = DeviceManager.shared.device(withID: deviceID) else { return nil }
        return StoredLocation(deviceID: device.persistentID, deviceName: device.name, storageID: storageID,
                              storageName: resolved?.storage.displayName ?? "", path: path.map(\.name))
    }
}

/// 跨连接、跨启动保存的位置：用于收藏、窗口恢复、每个文件夹的显示偏好
struct StoredLocation: Codable, Hashable {
    /// `MTPDevice.persistentID`
    var deviceID: String
    var deviceName: String
    var storageID: UInt32
    var storageName: String
    var path: [String]

    var name: String { path.last ?? storageName }

    /// 偏好设置用的键
    var key: String { ([deviceID, String(storageID)] + path).joined(separator: "/") }

    /// 设备已就绪时，按名字逐级找回句柄，得到一个可浏览的位置
    @MainActor func resolve() async -> BrowserLocation? {
        guard let device = DeviceManager.shared.readyDevice(persistentID: deviceID), let session = device.session,
              device.storages.contains(where: { $0.id == storageID }) else { return nil }
        if path.isEmpty { return BrowserLocation(deviceID: device.id, storageID: storageID) }
        guard let components = try? await session.resolve(path: path, storage: storageID, priority: .interactive) else { return nil }
        return BrowserLocation(deviceID: device.id, storageID: storageID, path: components)
    }
}
