import Foundation

/// 一台设备的 MTP 会话：独占这台设备的指令通道，按优先级调度所有请求。
///
/// - 单条指令用 `send(_:outData:priority:)`。
/// - 必须连续执行的一组指令（如 SendObjectInfo + SendObject，或一批 GetObjectInfo）用 `exclusive(priority:_:)`，
///   期间其他请求不会插进来。
/// - 长任务（大文件分块）每块单独申请通道，块与块之间高优先级请求自然会插队。
public final class MTPSession: Sendable {
    public let deviceInfo: PTPDeviceInfo
    private let transport: any PTPTransport
    private let scheduler = ChannelScheduler()

    public init(transport: any PTPTransport, deviceInfo: PTPDeviceInfo) {
        self.transport = transport
        self.deviceInfo = deviceInfo
    }

    /// 单条 outData 的上限
    public var maxOutDataLength: Int { transport.maxOutDataLength }

    /// 发送一条指令，响应码不是 OK 时抛 `PTPError.response`
    @discardableResult
    public func send(_ command: PTPCommand, outData: Data? = nil, priority: RequestPriority) async throws -> PTPResponse {
        try await exclusive(priority: priority) { try await $0.send(command, outData: outData) }
    }

    /// 独占通道执行一组连续指令
    public func exclusive<T: Sendable>(priority: RequestPriority, _ body: @Sendable (PTPChannel) async throws -> T) async throws -> T {
        try await scheduler.acquire(priority)
        do {
            let result = try await body(PTPChannel(transport: transport))
            await scheduler.release()
            return result
        } catch {
            await scheduler.release()
            throw error
        }
    }

    /// 是否有比 `priority` 更高优先级的请求在排队。长任务可以用它决定缩小块大小。
    public func hasWaiters(above priority: RequestPriority) async -> Bool {
        guard let p = await scheduler.highestWaitingPriority else { return false }
        return p > priority
    }
}

/// 在 `MTPSession.exclusive` 里使用的通道句柄
public struct PTPChannel: Sendable {
    let transport: any PTPTransport

    @discardableResult
    public func send(_ command: PTPCommand, outData: Data? = nil) async throws -> PTPResponse {
        if let outData, outData.count > transport.maxOutDataLength {
            // ImageCaptureCore 遇到 ≥ 4 GB 的 outData 会直接让进程崩溃（无法捕获），必须在这里拦住
            throw PTPError.payloadTooLarge(outData.count)
        }
        let response = try await transport.execute(command, outData: outData)
        guard response.code == .ok else { throw PTPError.response(response.code, command.operation) }
        return response
    }
}
