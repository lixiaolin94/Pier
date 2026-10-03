import Foundation

/// 设备上的一个对象（文件或文件夹）
public struct MTPObject: Sendable, Hashable, Identifiable {
    public var handle: UInt32
    public var storageID: UInt32
    public var parent: UInt32
    public var name: String
    public var format: PTPObjectFormat
    public var size: UInt64
    public var modified: Date?

    public var id: UInt32 { handle }
    public var isFolder: Bool { format == .association }

    public init(handle: UInt32, storageID: UInt32, parent: UInt32, name: String, format: PTPObjectFormat, size: UInt64, modified: Date?) {
        self.handle = handle
        self.storageID = storageID
        self.parent = parent
        self.name = name
        self.format = format
        self.size = size
        self.modified = modified
    }
}

/// 设备上的一个存储
public struct MTPStorage: Sendable, Hashable, Identifiable {
    public var id: UInt32
    public var info: PTPStorageInfo

    public init(id: UInt32, info: PTPStorageInfo) {
        self.id = id
        self.info = info
    }

    /// 显示名：优先描述，其次卷标
    public var displayName: String {
        let d = info.storageDescription.trimmingCharacters(in: .whitespaces)
        if !d.isEmpty { return d }
        if !info.volumeLabel.isEmpty { return info.volumeLabel }
        return String(format: "存储 %08X", id)
    }

    public var isReadOnly: Bool { info.accessCapability != .readWrite }

    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - 常用 MTP 操作

extension MTPSession {
    public func storages(priority: RequestPriority = .interactive) async throws -> [MTPStorage] {
        try await exclusive(priority: priority) { ch in
            var r = PTPDataReader(try await ch.send(PTPCommand(.getStorageIDs)).data)
            var result: [MTPStorage] = []
            for id in try r.array32() {
                // 有些设备会列出不可用的存储（如未插卡），跳过取不到信息的
                guard let resp = try? await ch.send(PTPCommand(.getStorageInfo, [id])),
                      let info = try? PTPStorageInfo(data: resp.data) else { continue }
                result.append(MTPStorage(id: id, info: info))
            }
            return result
        }
    }

    public func objectHandles(storage: UInt32, parent: UInt32, priority: RequestPriority) async throws -> [UInt32] {
        let resp = try await send(PTPCommand(.getObjectHandles, [storage, PTPHandle.allFormats, parent]), priority: priority)
        var r = PTPDataReader(resp.data)
        return try r.array32()
    }

    /// 读取一批对象的信息。整批独占通道，避免与后台传输逐条交错。
    public func objects(_ handles: [UInt32], priority: RequestPriority) async throws -> [MTPObject] {
        let supports64 = deviceInfo.supports(.getObjectPropValue)
        return try await exclusive(priority: priority) { ch in
            var result: [MTPObject] = []
            result.reserveCapacity(handles.count)
            for h in handles {
                let info: PTPObjectInfo
                do {
                    info = try PTPObjectInfo(data: try await ch.send(PTPCommand(.getObjectInfo, [h])).data)
                } catch let e as PTPError where e.responseCode == .invalidObjectHandle {
                    continue   // 列出后又被删掉的对象
                }
                var size = UInt64(info.compressedSize)
                if info.compressedSize == 0xFFFF_FFFF && supports64 && !info.isFolder {
                    // > 4 GB：ObjectInfo 里放不下，读 64 位的 ObjectSize 属性
                    if let d = try? await ch.send(PTPCommand(.getObjectPropValue, [h, UInt32(MTPObjectProperty.objectSize.rawValue)])).data {
                        var r = PTPDataReader(d)
                        size = (try? r.u64()) ?? size
                    }
                }
                result.append(MTPObject(handle: h, storageID: info.storageID, parent: info.parent, name: info.filename,
                                        format: info.format, size: info.isFolder ? 0 : size, modified: info.modificationDate.ptpDate))
            }
            return result
        }
    }

    /// 分批列出一个文件夹的内容：先拿全部 handle，再每批 `batchSize` 个读取信息并回调，界面可以边读边显示
    public func listChildren(storage: UInt32, parent: UInt32, priority: RequestPriority = .interactive,
                             batchSize: Int = 64) -> AsyncThrowingStream<[MTPObject], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let handles = try await objectHandles(storage: storage, parent: parent, priority: priority)
                    var start = 0
                    if handles.isEmpty { continuation.yield([]) }
                    while start < handles.count {
                        try Task.checkCancellation()
                        let batch = Array(handles[start..<min(start + batchSize, handles.count)])
                        continuation.yield(try await objects(batch, priority: priority))
                        start += batch.count
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func createFolder(named name: String, storage: UInt32, parent: UInt32, priority: RequestPriority = .userInitiated) async throws -> UInt32 {
        let info = PTPObjectInfo(storageID: storage, format: .association, size: 0, parent: parent, filename: name)
        let resp = try await send(PTPCommand(.sendObjectInfo, [storage, parent]), outData: info.encoded(), priority: priority)
        guard resp.parameters.count >= 3 else { throw PTPError.malformedData("SendObjectInfo 响应缺少新对象句柄") }
        return resp.parameters[2]
    }

    public func rename(_ handle: UInt32, to name: String, priority: RequestPriority = .userInitiated) async throws {
        var w = PTPDataWriter()
        w.string(name)
        try await send(PTPCommand(.setObjectPropValue, [handle, UInt32(MTPObjectProperty.objectFileName.rawValue)]), outData: w.data, priority: priority)
    }

    public func delete(_ handle: UInt32, priority: RequestPriority = .userInitiated) async throws {
        try await send(PTPCommand(.deleteObject, [handle, 0]), priority: priority)
    }

    /// 读取对象的一段数据。偏移超过 4 GB 时自动使用 Android 扩展 GetPartialObject64。
    public func read(_ handle: UInt32, offset: UInt64, length: UInt32, priority: RequestPriority) async throws -> Data {
        let command: PTPCommand
        if offset + UInt64(length) <= 0xFFFF_FFFF || !deviceInfo.supports(.getPartialObject64) {
            command = PTPCommand(.getPartialObject, [handle, UInt32(truncatingIfNeeded: offset), length])
        } else {
            command = PTPCommand(.getPartialObject64, [handle, UInt32(offset & 0xFFFF_FFFF), UInt32(offset >> 32), length])
        }
        return try await send(command, priority: priority).data
    }
}
