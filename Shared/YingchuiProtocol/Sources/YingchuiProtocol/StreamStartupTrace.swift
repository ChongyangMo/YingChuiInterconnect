import Foundation

/// 每次启动只记录各阶段一次；用单调时间计时，不受两端时钟差影响。
public final class StreamStartupTrace: @unchecked Sendable {
    private let started: UInt64
    private let requestID: UUID
    private let log: DiagnosticEventLog
    private let lock = NSLock()
    private var stages: Set<String> = []

    public init(requestID: UUID, log: DiagnosticEventLog) {
        self.requestID = requestID
        self.log = log
        started = DispatchTime.now().uptimeNanoseconds
    }

    public func mark(_ stage: String, detail: String = "") {
        lock.lock()
        let inserted = stages.insert(stage).inserted
        lock.unlock()
        guard inserted else { return }
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        log.record("回传启动计时：请求 \(requestID)，\(stage)，累计 \(String(format: "%.1f", milliseconds)) 毫秒\(detail.isEmpty ? "" : "，" + detail)")
    }
}
