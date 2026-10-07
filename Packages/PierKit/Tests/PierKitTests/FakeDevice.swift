import Foundation
@testable import PierKit

/// 内存里的假 MTP 设备：实现传输用到的指令，用来测试传输引擎和队列。
/// 行为模仿 DBI：根目录对象的 ParentObject 填存储 ID；SendObjectInfo 之后就留下一个 0 字节对象。
final class FakeDevice: PTPTransport, @unchecked Sendable {
    struct Object {
        var storage: UInt32
        /// 0 表示存储根目录
        var parent: UInt32
        var name: String
        var isFolder: Bool
        var data = Data()
        /// SendObjectPropList 声明了超过 truncateAt 的大小：DBI 会拆分存储，不截断
        var split = false
    }

    static let storage: UInt32 = 0x0001_0001

    private let lock = NSLock()
    private var objects: [UInt32: Object] = [:]
    private var nextHandle: UInt32 = 0x100
    private var lastCreated: UInt32?
    private(set) var operations: [PTPOperation] = []
    private(set) var declaredSizes: [UInt32] = []
    let maxOutDataLength: Int
    /// 模拟 FAT32：写入超过这个大小的部分被静默丢弃
    var truncateAt: Int?
    /// 模拟 DBI 安装存储：收完就安装，设备上留下的对象大小是 0
    var consumesUploads = false
    let delay: Duration

    init(maxOutDataLength: Int = 1 << 30, delay: Duration = .zero) {
        self.maxOutDataLength = maxOutDataLength
        self.delay = delay
    }

    // MARK: 测试辅助

    @discardableResult
    func add(_ name: String, in parent: UInt32 = 0, folder: Bool = false, data: Data = Data()) -> UInt32 {
        lock.withLock {
            nextHandle += 1
            objects[nextHandle] = Object(storage: Self.storage, parent: parent, name: name, isFolder: folder, data: data)
            return nextHandle
        }
    }

    func find(_ path: [String]) -> Object? {
        lock.withLock {
            var parent: UInt32 = 0
            var found: Object?
            for name in path {
                guard let (h, o) = objects.first(where: { $0.value.parent == parent && $0.value.name == name }) else { return nil }
                parent = h
                found = o
            }
            return found
        }
    }

    var objectCount: Int { lock.withLock { objects.count } }

    func ops() -> [PTPOperation] { lock.withLock { operations } }

    // MARK: PTPTransport

    func execute(_ command: PTPCommand, outData: Data?) async throws -> PTPResponse {
        if delay > .zero { try await Task.sleep(for: delay) }
        return lock.withLock { handle(command, outData) }
    }

    private func handle(_ command: PTPCommand, _ out: Data?) -> PTPResponse {
        operations.append(command.operation)
        let p = command.parameters
        func ok(_ params: [UInt32] = [], _ data: Data = Data()) -> PTPResponse { PTPResponse(code: .ok, parameters: params, data: data) }
        func fail(_ code: PTPResponseCode) -> PTPResponse { PTPResponse(code: code) }

        switch command.operation {
        case .getObjectHandles:
            let parent = p[2] == PTPHandle.root ? 0 : p[2]
            var w = PTPDataWriter()
            let handles = objects.filter { $0.value.parent == parent }.keys.sorted()
            w.u32(UInt32(handles.count))
            handles.forEach { w.u32($0) }
            return ok([], w.data)

        case .getObjectInfo:
            guard let o = objects[p[0]] else { return fail(.invalidObjectHandle) }
            let info = PTPObjectInfo(storageID: o.storage, format: o.isFolder ? .association : .undefined,
                                     size: UInt64(o.data.count), parent: o.parent == 0 ? o.storage : o.parent, filename: o.name)
            return ok([], info.encoded())

        case .getObjectPropValue:
            guard let o = objects[p[0]] else { return fail(.invalidObjectHandle) }
            var w = PTPDataWriter()
            w.u64(UInt64(o.data.count))
            return ok([], w.data)

        case .getPartialObject, .getPartialObject64:
            guard let o = objects[p[0]] else { return fail(.invalidObjectHandle) }
            let offset = command.operation == .getPartialObject ? Int(p[1]) : Int(UInt64(p[1]) | UInt64(p[2]) << 32)
            let length = Int(p.last!)
            guard offset <= o.data.count else { return fail(.invalidParameter) }
            return ok([], o.data.subdata(in: offset..<min(offset + length, o.data.count)))

        case .sendObjectInfo:
            guard let out, let info = try? PTPObjectInfo(data: out) else { return fail(.invalidParameter) }
            let parent = p[1] == PTPHandle.root ? 0 : p[1]
            if objects.contains(where: { $0.value.parent == parent && $0.value.name == info.filename }) { return fail(.generalError) }
            nextHandle += 1
            objects[nextHandle] = Object(storage: p[0], parent: parent, name: info.filename, isFolder: info.isFolder)
            lastCreated = nextHandle
            declaredSizes.append(info.compressedSize)
            return ok([p[0], p[1], nextHandle])

        case .sendObject:
            guard let h = lastCreated else { return fail(.generalError) }
            lastCreated = nil
            let data = out ?? Data()
            if data.isEmpty { return fail(.generalError) }   // DBI 的行为
            objects[h]?.data = consumesUploads ? Data() : truncate(data)
            return ok()

        case .sendObjectPropList:
            // 只认一个元素：ObjectFileName
            guard let out else { return fail(.invalidParameter) }
            var r = PTPDataReader(out)
            guard (try? r.u32()) == 1, (try? r.u32()) == 0, (try? r.u16()) == MTPObjectProperty.objectFileName.rawValue,
                  (try? r.u16()) == 0xFFFF, let name = try? r.string() else { return fail(.invalidParameter) }
            let parent = p[1] == PTPHandle.root ? 0 : p[1]
            if objects.contains(where: { $0.value.parent == parent && $0.value.name == name }) { return fail(.generalError) }
            let declared = Int(UInt64(p[3]) << 32 | UInt64(p[4]))
            nextHandle += 1
            objects[nextHandle] = Object(storage: p[0], parent: parent, name: name, isFolder: false,
                                         split: truncateAt.map { declared > $0 } ?? false)
            declaredSizes.append(UInt32(clamping: declared))
            return ok([p[0], p[1], nextHandle])

        case .beginEditObject, .endEditObject:
            return objects[p[0]] == nil ? fail(.invalidObjectHandle) : ok()

        case .sendPartialObject:
            guard var o = objects[p[0]], let out else { return fail(.invalidObjectHandle) }
            let offset = Int(UInt64(p[1]) | UInt64(p[2]) << 32)
            if o.data.count < offset { o.data.append(Data(count: offset - o.data.count)) }
            o.data.replaceSubrange(offset..<min(offset + out.count, o.data.count), with: out)
            if !o.split { o.data = truncate(o.data) }
            objects[p[0]] = o
            return ok()

        case .deleteObject:
            guard objects[p[0]] != nil else { return fail(.invalidObjectHandle) }
            removeRecursively(p[0])
            return ok()

        case .setObjectPropValue:
            guard objects[p[0]] != nil, let out else { return fail(.invalidObjectHandle) }
            var r = PTPDataReader(out)
            objects[p[0]]?.name = (try? r.string()) ?? ""
            return ok()

        case .moveObject:
            guard objects[p[0]] != nil else { return fail(.invalidObjectHandle) }
            objects[p[0]]?.parent = p[2] == PTPHandle.root ? 0 : p[2]
            return ok()

        default:
            return fail(.operationNotSupported)
        }
    }

    private func truncate(_ d: Data) -> Data {
        guard let truncateAt, d.count > truncateAt else { return d }
        return d.prefix(truncateAt)
    }

    private func removeRecursively(_ h: UInt32) {
        for child in objects.filter({ $0.value.parent == h }).keys { removeRecursively(child) }
        objects[h] = nil
    }

    // MARK: DeviceInfo

    static let allOperations: [PTPOperation] = [
        .getDeviceInfo, .getStorageIDs, .getStorageInfo, .getObjectHandles, .getObjectInfo, .getObject, .deleteObject,
        .sendObjectInfo, .sendObject, .moveObject, .getPartialObject, .getPartialObject64, .sendPartialObject,
        .truncateObject, .beginEditObject, .endEditObject, .getObjectPropsSupported, .getObjectPropValue, .setObjectPropValue, .sendObjectPropList,
    ]

    static func deviceInfo(operations: [PTPOperation] = allOperations, manufacturer: String = "Google") throws -> PTPDeviceInfo {
        var w = PTPDataWriter()
        w.u16(100); w.u32(6); w.u16(100); w.string("microsoft.com: 1.0; android.com: 1.0;"); w.u16(0)
        w.u32(UInt32(operations.count)); operations.forEach { w.u16($0.rawValue) }
        w.u32(0); w.u32(0); w.u32(0); w.u32(0)
        w.string(manufacturer); w.string("Fake"); w.string("1.0"); w.string("SN1")
        return try PTPDeviceInfo(data: w.data)
    }
}

extension Data {
    /// 可预测的测试数据
    static func pattern(_ count: Int, seed: UInt8 = 0) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }
}
