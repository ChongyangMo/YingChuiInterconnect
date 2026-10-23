import Foundation

/// 仅使用真实往返与成功补发样本；无足够样本时保持原有九十毫秒上限。
public struct AdaptiveVideoRepairPolicy: Sendable {
    private var roundTrips: [Double] = []
    private var repairs: [Double] = []
    private var recoverySuccessesNeeded = 0
    public init() {}

    public mutating func recordRoundTrip(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds > 0, milliseconds <= 10_000 else { return }
        roundTrips.append(milliseconds)
        if roundTrips.count > 32 { roundTrips.removeFirst() }
    }

    public mutating func recordRepair(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0, milliseconds <= 10_000 else { return }
        repairs.append(milliseconds)
        if repairs.count > 16 { repairs.removeFirst() }
        recoverySuccessesNeeded = max(0, recoverySuccessesNeeded - 1)
    }

    public mutating func recordFailure() { recoverySuccessesNeeded = 3 }

    public var waitNanoseconds: UInt64 {
        guard recoverySuccessesNeeded == 0, roundTrips.count >= 4 || repairs.count >= 3 else { return 90_000_000 }
        func p95(_ samples: [Double]) -> Double {
            guard !samples.isEmpty else { return 0 }
            let sorted = samples.sorted()
            return sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
        }
        let milliseconds = min(90, max(40, max(p95(roundTrips) * 2 + 8, p95(repairs) * 1.5 + 8)))
        return UInt64(ceil(milliseconds * 1_000_000))
    }
}
