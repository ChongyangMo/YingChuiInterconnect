import Foundation

/// 静止时仅响应接收端的刷新请求；挂起和空白状态不自动重启。
struct MacCaptureRecoveryPolicy {
    private var lastInteraction: UInt64?
    private var attempts: [UInt64] = []
    private var healthySince: UInt64?
    private var lastHealthyCapture: UInt64?

    mutating func recordCapture(now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        if let previous = lastHealthyCapture, now >= previous, now - previous <= 100_000_000 {
            if let healthySince, now >= healthySince, now - healthySince >= 1_000_000_000 {
                attempts.removeAll(keepingCapacity: true)
            }
        } else {
            healthySince = now
        }
        lastHealthyCapture = now
    }

    mutating func recordInteraction(now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lastInteraction = now
    }

    func shouldRecover(lastCapture: UInt64?, wasComplete: Bool, isRecovering: Bool,
                       receiverRequestedRefresh: Bool = false,
                       now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
        guard !isRecovering, wasComplete || receiverRequestedRefresh,
              let lastCapture, now >= lastCapture else { return false }
        let interactive = lastInteraction.map { now >= $0 && now - $0 <= 1_000_000_000 } ?? false
        return now - lastCapture >= (interactive ? 200_000_000 : 500_000_000)
    }

    mutating func beginRecovery(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
        attempts.removeAll { now >= $0 && now - $0 >= 10_000_000_000 }
        guard attempts.count < 3 else { return false }
        attempts.append(now)
        healthySince = nil
        lastHealthyCapture = nil
        return true
    }
}
