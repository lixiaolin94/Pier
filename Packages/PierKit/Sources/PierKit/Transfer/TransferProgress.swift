import Foundation
import os

/// 一个传输任务的进度计数器。传输在后台线程上累加，界面定时读取快照。
public final class TransferProgress: Sendable {
    public struct Snapshot: Sendable, Equatable {
        public var totalBytes: UInt64 = 0
        public var completedBytes: UInt64 = 0
        public var totalFiles = 0
        public var completedFiles = 0
        public var currentName = ""
        /// 当前这段进度是按经验速度估算的（单次 SendObject 拿不到真实进度）
        public var isEstimated = false

        public var fraction: Double {
            guard totalBytes > 0 else { return totalFiles > 0 ? Double(completedFiles) / Double(totalFiles) : 0 }
            return min(1, Double(completedBytes) / Double(totalBytes))
        }
    }

    private struct State {
        var snapshot = Snapshot()
        var estimateStart: Date?
        var estimateBytes: UInt64 = 0
        var estimateRate: Double = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public var snapshot: Snapshot {
        state.withLock { s in
            var snap = s.snapshot
            if let start = s.estimateStart {
                // 估算最多走到 95%，剩下的等真正完成
                let guess = min(Date().timeIntervalSince(start) * s.estimateRate, Double(s.estimateBytes) * 0.95)
                snap.completedBytes += UInt64(max(0, guess))
                snap.isEstimated = true
            }
            return snap
        }
    }

    public func setTotals(bytes: UInt64, files: Int) {
        state.withLock {
            $0.snapshot.totalBytes = bytes
            $0.snapshot.totalFiles = files
        }
    }

    public func reset(completedBytes: UInt64 = 0, completedFiles: Int = 0) {
        state.withLock {
            $0.snapshot.completedBytes = completedBytes
            $0.snapshot.completedFiles = completedFiles
            $0.estimateStart = nil
        }
    }

    public func addBytes(_ n: UInt64) {
        guard n > 0 else { return }
        state.withLock { $0.snapshot.completedBytes += n }
    }

    public func fileCompleted() {
        state.withLock { $0.snapshot.completedFiles += 1 }
    }

    public func setCurrent(_ name: String) {
        state.withLock { $0.snapshot.currentName = name }
    }

    func beginEstimate(bytes: UInt64, rate: Double) {
        state.withLock {
            $0.estimateStart = Date()
            $0.estimateBytes = bytes
            $0.estimateRate = rate
        }
    }

    func endEstimate() {
        state.withLock { $0.estimateStart = nil }
    }
}
