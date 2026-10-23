public struct StreamRecoveryPolicy: Sendable {
    public let maximumAttempts: Int
    private var attempt = 0
    private var healthyIntervals = 0

    public init(maximumAttempts: Int = 3) {
        self.maximumAttempts = max(1, maximumAttempts)
    }

    public mutating func nextDelaySeconds() -> Int? {
        healthyIntervals = 0
        guard attempt < maximumAttempts else { return nil }
        let delay = 1 << min(attempt, 3)
        attempt += 1
        return delay
    }

    /// 只有连续五个实际解码有进展的统计周期，才结束一次故障周期。
    public mutating func recordHealthyInterval() {
        healthyIntervals += 1
        if healthyIntervals >= 5 { reset() }
    }

    public mutating func recordStalledInterval() { healthyIntervals = 0 }

    public mutating func reset() {
        attempt = 0
        healthyIntervals = 0
    }
}
