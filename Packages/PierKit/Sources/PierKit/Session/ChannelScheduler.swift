import Foundation

/// 请求优先级。数值越大越先执行。
///
/// PTP 是一条串行管道：同一时刻只能执行一条指令。为了让界面始终流畅，
/// 浏览、取可见项信息这类前台请求总是插到后台传输的前面。
public enum RequestPriority: Int, Comparable, Sendable, CaseIterable {
    /// 大文件分块、缩略图、递归搜索
    case background = 0
    /// 用户刚发起的小任务（新建文件夹、改名、删除、小文件传输）
    case userInitiated = 1
    /// 界面正在等待的请求（列目录、Quick Look 首块）
    case interactive = 2

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// 按优先级分配"指令通道"的调度器：高优先级先拿，同优先级先来先得。支持在排队时取消。
actor ChannelScheduler {
    private struct Waiter {
        let id: UInt64
        let priority: RequestPriority
        let continuation: CheckedContinuation<Void, Error>
    }

    private var busy = false
    private var waiters: [Waiter] = []
    private var nextID: UInt64 = 0

    /// 当前排队中的最高优先级（没有排队时为 nil）。长任务在块与块之间用它判断要不要让路。
    var highestWaitingPriority: RequestPriority? { waiters.map(\.priority).max() }

    func acquire(_ priority: RequestPriority) async throws {
        if !busy && waiters.isEmpty {
            busy = true
            return
        }
        nextID += 1
        let id = nextID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    c.resume(throwing: CancellationError())
                    return
                }
                // 插入到同优先级队尾，保持高优先级在前
                let index = waiters.firstIndex { $0.priority < priority } ?? waiters.endIndex
                waiters.insert(Waiter(id: id, priority: priority, continuation: c), at: index)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            // busy 保持 true，所有权直接交给下一个
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).continuation.resume(throwing: CancellationError())
    }
}
