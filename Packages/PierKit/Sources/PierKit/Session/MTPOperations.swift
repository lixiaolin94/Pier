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

/// 路径上的一级：句柄只在本次 MTP 会话内有效，名字用来在重连后重新定位
public struct MTPPathComponent: Sendable, Hashable, Codable {
    public var handle: UInt32
    public var name: String

    public init(handle: UInt32, name: String) {
        self.handle = handle
        self.name = name
    }
}

/// 递归搜索的一条结果
public struct MTPSearchHit: Sendable {
    public var object: MTPObject
    /// 从搜索起点到这个对象所在文件夹的路径（不含对象本身）
    public var folderPath: [MTPPathComponent]
}

extension Array where Element == MTPObject {
    /// 按名字去重，保留先出现的。DBI 会给新建的对象再登记一个重复 handle（见 CONTEXT.md），同一文件夹里名字本来就唯一。
    public func dedupedByName() -> [MTPObject] {
        var seen = Set<String>()
        return filter { seen.insert($0.name).inserted }
    }
}

extension MTPSession {
    /// 读取单个对象的信息
    public func object(_ handle: UInt32, priority: RequestPriority) async throws -> MTPObject {
        guard let object = try await objects([handle], priority: priority).first else {
            throw PTPError.response(.invalidObjectHandle, .getObjectInfo)
        }
        return object
    }

    /// 对象的真实大小（优先读 64 位的 ObjectSize 属性）
    public func objectSize(_ handle: UInt32, priority: RequestPriority) async throws -> UInt64 {
        if deviceInfo.supports(.getObjectPropValue),
           let data = try? await send(PTPCommand(.getObjectPropValue, [handle, UInt32(MTPObjectProperty.objectSize.rawValue)]), priority: priority).data {
            var r = PTPDataReader(data)
            if let size = try? r.u64() { return size }
        }
        let info = try PTPObjectInfo(data: try await send(PTPCommand(.getObjectInfo, [handle]), priority: priority).data)
        return UInt64(info.compressedSize)
    }

    /// 一次读出文件夹的全部内容（已按名字去重）
    public func children(storage: UInt32, parent: UInt32, priority: RequestPriority) async throws -> [MTPObject] {
        var result: [MTPObject] = []
        for try await batch in listChildren(storage: storage, parent: parent, priority: priority, batchSize: 128) {
            result += batch
        }
        return result.dedupedByName()
    }

    /// 移动对象到同一设备的另一个文件夹。不要把 parent 传 0（DBI 会返回 OK 但行为不明）。
    public func move(_ handle: UInt32, toStorage storage: UInt32, parent: UInt32, priority: RequestPriority = .userInitiated) async throws {
        precondition(parent != 0, "MoveObject 的 parent 不能为 0")
        try await send(PTPCommand(.moveObject, [handle, storage, parent]), priority: priority)
    }

    /// 按名字逐级查找路径（重连后句柄失效时用）。找不到返回 nil；空路径返回 nil（表示存储根目录）。
    public func resolve(path names: [String], storage: UInt32, priority: RequestPriority) async throws -> [MTPPathComponent]? {
        var parent = PTPHandle.root
        var result: [MTPPathComponent] = []
        for name in names {
            let children = try await children(storage: storage, parent: parent, priority: priority)
            guard let match = children.first(where: { $0.name == name }) else { return nil }
            result.append(MTPPathComponent(handle: match.handle, name: match.name))
            parent = match.handle
        }
        return result
    }

    /// 在某个文件夹下递归搜索名字包含 `query` 的项目（广度优先，后台优先级）。每读完一个文件夹回调一批结果。
    public func search(storage: UInt32, under root: UInt32, matching query: String,
                       priority: RequestPriority = .background, folderLimit: Int = 20_000) -> AsyncThrowingStream<[MTPSearchHit], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var queue: [(handle: UInt32, path: [MTPPathComponent])] = [(root, [])]
                    var visited = 0
                    while !queue.isEmpty, visited < folderLimit {
                        try Task.checkCancellation()
                        let (folder, path) = queue.removeFirst()
                        visited += 1
                        let items: [MTPObject]
                        do {
                            items = try await children(storage: storage, parent: folder, priority: priority)
                        } catch let e as PTPError where e.responseCode != nil {
                            continue   // 某个文件夹读不了（权限等），跳过
                        }
                        let hits = items.filter { $0.name.localizedCaseInsensitiveContains(query) }
                            .map { MTPSearchHit(object: $0, folderPath: path) }
                        if !hits.isEmpty { continuation.yield(hits) }
                        for item in items where item.isFolder {
                            queue.append((item.handle, path + [MTPPathComponent(handle: item.handle, name: item.name)]))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
