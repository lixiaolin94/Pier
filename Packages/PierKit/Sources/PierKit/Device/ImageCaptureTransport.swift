import Foundation
@preconcurrency import ImageCaptureCore
import os

/// 通过 ImageCaptureCore（经 ptpcamerad 中转）发送原始 PTP 指令。
///
/// 已验证的要点（见 CONTEXT.md「验证记录」）：
/// - 命令是完整的 PTP USB 命令 container；completion 第一个参数是数据阶段负载，第二个是响应 container。
/// - outData 会被内联进 XPC 消息，≥ 2^32 字节时进程直接崩溃，所以上限是 4 GB − 13 字节（再扣掉 12 字节头）。
/// - 不要发 OpenSession，框架已经开好。
final class ImageCaptureTransport: PTPTransport, @unchecked Sendable {
    // ICCameraDevice 不是 Sendable；它只在主线程上被访问
    private let device: ICCameraDevice
    private let transactionID = OSAllocatedUnfairLock(initialState: UInt32(1))

    let maxOutDataLength = 4_294_967_283

    init(device: ICCameraDevice) {
        self.device = device
    }

    func execute(_ command: PTPCommand, outData: Data?) async throws -> PTPResponse {
        let txid = transactionID.withLock { id -> UInt32 in
            defer { id = id == 0xFFFF_FFFE ? 1 : id + 1 }
            return id
        }
        let container = command.container(transactionID: txid)
        let timeout = Self.timeout(for: command, outBytes: outData?.count ?? 0)
        let device = self.device

        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            DispatchQueue.main.async {
                device.requestSendPTPCommand(container, outData: outData) { data, responseContainer, error in
                    if let error {
                        once.resume(throwing: PTPError.transport(error.localizedDescription))
                        return
                    }
                    do {
                        once.resume(returning: try PTPResponse(responseContainer: responseContainer, data: data))
                    } catch {
                        once.resume(throwing: error)
                    }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.resume(throwing: PTPError.timeout(command.operation))
            }
        }
    }

    /// 超时时间：基础 30 秒，加上按 5 MB/s 估算的数据传输时间
    private static func timeout(for command: PTPCommand, outBytes: Int) -> TimeInterval {
        var t: TimeInterval = 30
        t += Double(outBytes) / 5_000_000
        if command.operation == .getObject { t += 600 }   // 整个对象读取，长度未知
        if command.operation == .getPartialObject || command.operation == .getPartialObject64,
           let len = command.parameters.last {
            t += Double(len) / 5_000_000
        }
        return t
    }
}

/// 保证 continuation 只 resume 一次（completion 与超时竞争）
private final class ResumeOnce<T: Sendable>: Sendable {
    private let state: OSAllocatedUnfairLock<CheckedContinuation<T, Error>?>

    init(_ c: CheckedContinuation<T, Error>) { state = OSAllocatedUnfairLock(initialState: c) }

    func resume(returning value: T) { take()?.resume(returning: value) }
    func resume(throwing error: Error) { take()?.resume(throwing: error) }

    private func take() -> CheckedContinuation<T, Error>? {
        state.withLock { c in
            defer { c = nil }
            return c
        }
    }
}
