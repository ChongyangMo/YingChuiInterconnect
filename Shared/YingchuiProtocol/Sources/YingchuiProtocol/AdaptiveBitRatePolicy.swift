import Foundation

public struct AdaptiveBitRatePolicy: Sendable {
    public private(set) var maximumBitRate: Int
    public private(set) var minimumBitRate: Int
    public private(set) var currentBitRate: Int
    private var healthyIntervals = 0
    private var poorIntervals = 0

    public init(maximumBitRate: Int, minimumBitRate: Int = 1_000_000) {
        let bounds = Self.normalizedBounds(
            maximumBitRate: maximumBitRate,
            minimumBitRate: minimumBitRate
        )
        self.maximumBitRate = bounds.maximum
        self.minimumBitRate = bounds.minimum
        currentBitRate = bounds.maximum
    }

    public mutating func reset(maximumBitRate: Int, minimumBitRate: Int = 1_000_000, initialBitRate: Int? = nil) {
        let bounds = Self.normalizedBounds(
            maximumBitRate: maximumBitRate,
            minimumBitRate: minimumBitRate
        )
        self.maximumBitRate = bounds.maximum
        self.minimumBitRate = bounds.minimum
        currentBitRate = min(bounds.maximum, max(bounds.minimum, initialBitRate ?? bounds.maximum))
        healthyIntervals = 0
        poorIntervals = 0
    }

    public mutating func evaluate(lossRate: Double) -> Int? {
        let nextBitRate: Int
        if lossRate > 0.05 {
            poorIntervals = 0
            healthyIntervals = 0
            nextBitRate = max(minimumBitRate, Int(Double(currentBitRate) * 0.75))
        } else if lossRate > 0.02 {
            poorIntervals += 1
            healthyIntervals = 0
            guard poorIntervals >= 2 else { return nil }
            poorIntervals = 0
            nextBitRate = max(minimumBitRate, Int(Double(currentBitRate) * 0.85))
        } else if lossRate < 0.003 {
            healthyIntervals += 1
            poorIntervals = 0
            guard healthyIntervals >= 8 else { return nil }
            healthyIntervals = 0
            nextBitRate = min(maximumBitRate, Int(Double(currentBitRate) * 1.15))
        } else {
            healthyIntervals = 0
            poorIntervals = 0
            return nil
        }

        let reachesConfiguredBoundary = nextBitRate == maximumBitRate
            || nextBitRate == minimumBitRate
        guard nextBitRate != currentBitRate,
              reachesConfiguredBoundary || abs(nextBitRate - currentBitRate) >= 100_000 else {
            return nil
        }
        currentBitRate = nextBitRate
        return nextBitRate
    }

    public mutating func restore(currentBitRate: Int) {
        self.currentBitRate = min(
            maximumBitRate,
            max(minimumBitRate, Self.normalized(currentBitRate))
        )
        healthyIntervals = 0
        poorIntervals = 0
    }

    private static func normalized(_ value: Int) -> Int {
        VideoStreamLimits.normalizedBitRate(value)
    }

    private static func normalizedBounds(
        maximumBitRate: Int,
        minimumBitRate: Int
    ) -> (minimum: Int, maximum: Int) {
        let maximum = normalized(maximumBitRate)
        return (min(normalized(minimumBitRate), maximum), maximum)
    }
}
