import Foundation

/// 仅累计数值，不保留逐帧数组；由所在流水线的串行队列访问。
public struct VideoTimingStatistics: Sendable {
    public private(set) var count: UInt64 = 0
    public private(set) var maximumNanoseconds: UInt64 = 0
    private var totalNanoseconds: Double = 0
    private var over33Milliseconds: UInt64 = 0

    public init() {}

    public mutating func record(_ nanoseconds: UInt64) {
        count &+= 1
        totalNanoseconds += Double(nanoseconds)
        maximumNanoseconds = max(maximumNanoseconds, nanoseconds)
        if nanoseconds > 33_333_333 { over33Milliseconds &+= 1 }
    }

    public mutating func record(from start: UInt64, to end: UInt64) {
        guard end >= start else { return }
        record(end - start)
    }

    public var summary: String {
        guard count > 0 else { return "无样本" }
        return String(format: "均值 %.1f/最大 %.1f 毫秒/超33毫秒 %llu次",
            totalNanoseconds / Double(count) / 1_000_000,
            Double(maximumNanoseconds) / 1_000_000, over33Milliseconds)
    }
}
