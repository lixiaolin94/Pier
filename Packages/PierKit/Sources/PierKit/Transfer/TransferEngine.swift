import Foundation
import os

/// 传输块大小等参数。默认值来自实测（CONTEXT.md「问题 3：吞吐量」）。
public struct TransferTuning: Sendable {
    /// 没有前台请求时的下载块：16 MB 时吞吐已饱和（约 38 MB/s），单块约 0.4 s
    public var largeChunk: Int
    /// 有前台请求排队时的下载块：约 60 ms 一块，浏览几乎无感
    public var smallChunk: Int
    /// 分段上传的块（SendPartialObject）
    public var uploadChunk: Int
    /// 有前台请求排队时的上传块
    public var smallUploadChunk: Int

    public static let `default` = TransferTuning(largeChunk: 16 << 20, smallChunk: 2 << 20, uploadChunk: 32 << 20, smallUploadChunk: 4 << 20)

    public init(largeChunk: Int, smallChunk: Int, uploadChunk: Int, smallUploadChunk: Int) {
        self.largeChunk = largeChunk
        self.smallChunk = smallChunk
        self.uploadChunk = uploadChunk
        self.smallUploadChunk = smallUploadChunk
    }
}

public enum TransferError: Error, LocalizedError, Sendable {
    /// 超过单条指令上限，设备又不支持分段写
    case tooLargeForDevice(UInt64)
    /// 写完回读大小不一致（DBI 往 FAT32 写 >4 GB 时会静默截断）
    case verificationFailed(expected: UInt64, actual: UInt64)
    /// 读 4 GB 以后的数据需要 GetPartialObject64，设备不支持
    case cannotReadBeyond4GB
    /// 设备上找不到要传的项目（可能已被删除或改名）
    case notFound(String)
    /// 本地文件在传输过程中被修改
    case localFileChanged(String)
    /// 设备上的名字冲突
    case nameConflict(String)
    /// 设备剩余空间不足
    case insufficientSpace(needed: UInt64, available: UInt64)
    /// 设备未连接
    case deviceUnavailable
    /// 往 DBI 安装存储写超过单条指令上限的文件：安装存储不接受分段写
    case tooLargeForInstall(UInt64)

    public var errorDescription: String? {
        let bytes = { (n: UInt64) in ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file) }
        switch self {
        case let .tooLargeForDevice(n):
            return String(localized: "文件太大（\(bytes(n))）：这台设备不支持分段写入，单个文件不能超过 4 GB。")
        case let .verificationFailed(expected, actual):
            var s = String(localized: "写入后校验失败：设备上的大小是 \(bytes(actual))，应为 \(bytes(expected))。")
            if expected > 0xFFFF_FFFF && actual <= 0xFFFF_FFFF {
                s += String(localized: "这个存储可能是 FAT32 格式，单个文件不能超过 4 GB。")
            }
            return s
        case let .tooLargeForInstall(n):
            return String(localized: "文件太大（\(bytes(n))）：DBI 的安装存储一次只能接收 4 GB 以内的文件。请把它传到 SD 卡，再在 DBI 里从 SD 卡安装。")
        case .cannotReadBeyond4GB:
            return String(localized: "这台设备不支持读取超过 4 GB 的文件。")
        case let .notFound(name):
            return String(localized: "设备上找不到“\(name)”，它可能已被移动或删除。")
        case let .localFileChanged(name):
            return String(localized: "“\(name)”在传输过程中被修改了。")
        case let .nameConflict(message):
            return message
        case let .insufficientSpace(needed, available):
            return String(localized: "设备空间不足：需要 \(bytes(needed))，可用 \(bytes(available))。")
        case .deviceUnavailable:
            return String(localized: "设备未连接。")
        }
    }
}

/// 上传速度的经验值，用来给拿不到真实进度的单次 SendObject 估算进度条
enum UploadRateEstimator {
    private static let rate = OSAllocatedUnfairLock(initialState: 30_000_000.0)   // 实测约 31 MB/s

    static var current: Double { rate.withLock { $0 } }

    static func record(bytes: UInt64, seconds: Double) {
        guard bytes >= 8 << 20, seconds > 0.05 else { return }   // 太小的样本误差大
        let sample = Double(bytes) / seconds
        rate.withLock { $0 = $0 * 0.5 + sample * 0.5 }
    }
}

// MARK: - 单个文件的下载 / 上传

extension MTPSession {
    /// 把一个对象下载到本地文件。文件已存在时从它的末尾续传。
    ///
    /// 每块单独申请指令通道，块与块之间前台请求可以插队；有前台请求排队时自动改用小块。
    @concurrent
    public func download(_ handle: UInt32, size: UInt64, into file: URL, progress: TransferProgress,
                         priority: RequestPriority = .background) async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: file.path) {
            guard fm.createFile(atPath: file.path, contents: nil) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: file]) }
        }
        let fh = try FileHandle(forWritingTo: file)
        defer { try? fh.close() }
        var offset = try fh.seekToEnd()
        if offset > size {
            try fh.truncate(atOffset: 0)
            offset = 0
        }
        progress.addBytes(offset)

        if size > 0xFFFF_FFFF && !quirks.canReadBeyond4GB { throw TransferError.cannotReadBeyond4GB }
        if !deviceInfo.supports(.getPartialObject) && !deviceInfo.supports(.getPartialObject64) {
            // 极少数设备只支持整个读取
            try Task.checkCancellation()
            let data = try await send(PTPCommand(.getObject, [handle]), priority: priority).data
            try fh.truncate(atOffset: 0)
            try fh.write(contentsOf: data)
            progress.addBytes(UInt64(data.count) &- offset)
            return
        }

        while offset < size {
            try Task.checkCancellation()
            let busy = await hasWaiters(above: priority)
            let chunk = UInt64(busy ? tuning.smallChunk : tuning.largeChunk)
            let length = UInt32(min(chunk, size - offset))
            let data = try await read(handle, offset: offset, length: length, priority: priority)
            guard !data.isEmpty else { throw PTPError.malformedData("设备在偏移 \(offset) 处返回了空数据") }
            let usable = data.prefix(Int(min(UInt64(data.count), size - offset)))
            try fh.write(contentsOf: usable)
            offset += UInt64(usable.count)
            progress.addBytes(UInt64(usable.count))
        }
    }

    /// 上传一个本地文件，返回新对象的句柄。失败或取消时会删掉设备上写了一半的对象。
    ///
    /// - 不超过单条指令上限：默认一次 SendObject（XPC 走共享内存映射，不占内存，但拿不到真实进度，按经验速度估算）。
    /// - `preferChunked` 且设备支持编辑扩展：首块 SendObject 建对象，再 BeginEdit + SendPartialObject × N + EndEdit。
    /// - 超过上限（约 4 GB）：只能分段，设备不支持就报错。
    /// 完成后回读大小校验（DBI 写失败时不报错）。`verify` 为 false 时跳过：DBI 的安装存储收完 NSP 就安装并收走文件，
    /// 回读只会读到 0，不能据此判失败、更不能删。
    @concurrent
    public func upload(file url: URL, name: String, storage: UInt32, parent: UInt32, progress: TransferProgress,
                       preferChunked: Bool, verify: Bool = true, priority: RequestPriority = .background) async throws -> UInt32 {
        let size = UInt64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let chunked: Bool
        if size > UInt64(maxOutDataLength) {
            guard quirks.canPartialWrite else { throw TransferError.tooLargeForDevice(size) }
            chunked = true
        } else {
            chunked = preferChunked && quirks.canPartialWrite && size > UInt64(tuning.uploadChunk)
        }

        let handle = chunked
            ? try await uploadChunked(url, size: size, name: name, storage: storage, parent: parent, progress: progress, priority: priority)
            : try await uploadSingle(url, size: size, name: name, storage: storage, parent: parent, progress: progress, priority: priority)

        // 0 字节文件没有可截断的内容，而 DBI 上这个句柄此时读不到，不做回读
        guard verify, size > 0 else { return handle }
        do {
            try Task.checkCancellation()
            let actual = try await objectSize(handle, priority: .userInitiated)
            guard actual == size else { throw TransferError.verificationFailed(expected: size, actual: actual) }
        } catch {
            await discard(handle)
            throw error
        }
        return handle
    }

    private func uploadSingle(_ url: URL, size: UInt64, name: String, storage: UInt32, parent: UInt32,
                              progress: TransferProgress, priority: RequestPriority) async throws -> UInt32 {
        let data = size == 0 ? Data() : try Data(contentsOf: url, options: .alwaysMapped)
        guard UInt64(data.count) == size else { throw TransferError.localFileChanged(name) }
        try Task.checkCancellation()
        let started = Date()
        progress.beginEstimate(bytes: size, rate: UploadRateEstimator.current)
        defer { progress.endEstimate() }
        let onlyInfo = size == 0 && quirks.zeroByteFilesNeedOnlyObjectInfo
        let handle = try await exclusive(priority: priority) { ch in
            let h = try await Self.sendObjectInfo(ch, name: name, size: size, storage: storage, parent: parent)
            if onlyInfo { return h }
            do {
                try await ch.send(PTPCommand(.sendObject), outData: data)
            } catch let e as PTPError where e.responseCode == .generalError && size == 0 {
                // DBI：0 字节文件的 SendObject 一定返回 0x2002，但文件其实已经建好了（随后的大小校验会确认）
            } catch {
                _ = try? await ch.send(PTPCommand(.deleteObject, [h, 0]))
                throw error
            }
            return h
        }
        progress.endEstimate()
        progress.addBytes(size)
        UploadRateEstimator.record(bytes: size, seconds: Date().timeIntervalSince(started))
        if Task.isCancelled {
            // SendObject 中途无法打断，只能传完再删
            await discard(handle)
            throw CancellationError()
        }
        return handle
    }

    private func uploadChunked(_ url: URL, size: UInt64, name: String, storage: UInt32, parent: UInt32,
                               progress: TransferProgress, priority: RequestPriority) async throws -> UInt32 {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        if quirks.chunkedUploadDeclaresFullSize {
            return try await uploadDeclaringFullSize(fh, size: size, name: name, storage: storage, parent: parent,
                                                     progress: progress, priority: priority)
        }
        let firstLength = Int(min(UInt64(tuning.uploadChunk), size))
        let first = try fh.read(upToCount: firstLength) ?? Data()
        guard first.count == firstLength else { throw TransferError.localFileChanged(name) }
        try Task.checkCancellation()

        // 首块：SendObjectInfo 声明的大小就是首块大小（Android 按声明的大小接收数据，声明多了会一直等）
        let handle = try await exclusive(priority: priority) { ch in
            let h = try await Self.sendObjectInfo(ch, name: name, size: UInt64(first.count), storage: storage, parent: parent)
            do {
                try await ch.send(PTPCommand(.sendObject), outData: first)
            } catch {
                _ = try? await ch.send(PTPCommand(.deleteObject, [h, 0]))
                throw error
            }
            return h
        }
        progress.addBytes(UInt64(first.count))

        return try await sendPartials(fh, from: UInt64(first.count), size: size, handle: handle, name: name,
                                      progress: progress, priority: priority)
    }

    /// DBI：SendObjectPropList 声明完整的 64 位大小建对象，然后全部用 SendPartialObject 从 0 写
    private func uploadDeclaringFullSize(_ fh: FileHandle, size: UInt64, name: String, storage: UInt32, parent: UInt32,
                                         progress: TransferProgress, priority: RequestPriority) async throws -> UInt32 {
        var w = PTPDataWriter()
        w.u32(1)                                                // 元素个数
        w.u32(0)                                                // ObjectHandle（新对象填 0）
        w.u16(MTPObjectProperty.objectFileName.rawValue)
        w.u16(0xFFFF)                                           // 数据类型：字符串
        w.string(name)
        let props = w.data
        let resp = try await send(PTPCommand(.sendObjectPropList, [storage, parent, UInt32(PTPObjectFormat.undefined.rawValue),
                                                                   UInt32(size >> 32), UInt32(size & 0xFFFF_FFFF)]),
                                  outData: props, priority: priority)
        guard resp.parameters.count >= 3 else { throw PTPError.malformedData("SendObjectPropList 响应缺少新对象句柄") }
        return try await sendPartials(fh, from: 0, size: size, handle: resp.parameters[2], name: name,
                                      progress: progress, priority: priority)
    }

    /// BeginEdit + SendPartialObject × N + EndEdit。失败或取消时删掉这个对象。
    private func sendPartials(_ fh: FileHandle, from start: UInt64, size: UInt64, handle: UInt32, name: String,
                              progress: TransferProgress, priority: RequestPriority) async throws -> UInt32 {
        var editing = false
        do {
            try fh.seek(toOffset: start)
            var offset = start
            if offset < size {
                try await send(PTPCommand(.beginEditObject, [handle]), priority: priority)
                editing = true
            }
            while offset < size {
                try Task.checkCancellation()
                let busy = await hasWaiters(above: priority)
                let length = Int(min(UInt64(busy ? tuning.smallUploadChunk : tuning.uploadChunk), size - offset))
                let chunk = try fh.read(upToCount: length) ?? Data()
                guard chunk.count == length else { throw TransferError.localFileChanged(name) }
                try await send(PTPCommand(.sendPartialObject, [handle, UInt32(offset & 0xFFFF_FFFF), UInt32(offset >> 32), UInt32(length)]),
                               outData: chunk, priority: priority)
                offset += UInt64(length)
                progress.addBytes(UInt64(length))
            }
            if editing {
                editing = false
                try await send(PTPCommand(.endEditObject, [handle]), priority: priority)
            }
        } catch {
            if editing { _ = try? await detached { try await self.send(PTPCommand(.endEditObject, [handle]), priority: .userInitiated) } }
            await discard(handle)
            throw error
        }
        return handle
    }

    private static func sendObjectInfo(_ ch: PTPChannel, name: String, size: UInt64, storage: UInt32, parent: UInt32) async throws -> UInt32 {
        let info = PTPObjectInfo(storageID: storage, format: .undefined, size: size, parent: parent, filename: name)
        let resp = try await ch.send(PTPCommand(.sendObjectInfo, [storage, parent]), outData: info.encoded())
        guard resp.parameters.count >= 3 else { throw PTPError.malformedData("SendObjectInfo 响应缺少新对象句柄") }
        return resp.parameters[2]
    }

    /// 删掉写了一半的对象。放在独立任务里执行，这样即使当前任务已被取消也能发出去。
    func discard(_ handle: UInt32) async {
        _ = try? await detached { try await self.delete(handle, priority: .userInitiated) }
    }

    private func detached<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await Task { try await body() }.value
    }
}
