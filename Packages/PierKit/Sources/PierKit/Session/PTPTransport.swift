import Foundation

/// 执行一条原始 PTP 指令的底层通道。
///
/// 实现者只负责"发出去、拿回来"：设备返回非 OK 响应码时**不抛错**，原样放在 `PTPResponse.code` 里；
/// 只有传输本身失败（断开、超时、框架报错）才抛 `PTPError`。调度、重试、响应码检查都在 `MTPSession` 里做。
/// 同一时刻只会有一条指令在执行（由 `MTPSession` 保证）。
public protocol PTPTransport: Sendable {
    func execute(_ command: PTPCommand, outData: Data?) async throws -> PTPResponse

    /// 单条指令 outData 的上限（ImageCaptureCore 约为 4 GB − 13 字节）
    var maxOutDataLength: Int { get }
}
