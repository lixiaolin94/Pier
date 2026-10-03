import Foundation
import PierKit

/// 一个浏览位置：哪台设备、哪个存储、哪个文件夹
struct BrowserLocation: Equatable {
    struct Folder: Equatable {
        var handle: UInt32
        var name: String
    }

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
}
