import Foundation

/// 仅供调试对比使用；有界保存真实样本，缺少样本时不生成统计值。
public struct VideoBenchmarkSamples: Sendable {
    public private(set) var milliseconds: [Double] = []

    public init() {}

    public mutating func record(milliseconds value: Double) {
        guard value.isFinite, value >= 0, value < 60_000, milliseconds.count < 4_096 else { return }
        milliseconds.append(value)
    }

    public mutating func record(from start: UInt64, to end: UInt64) {
        guard end >= start else { return }
        record(milliseconds: Double(end - start) / 1_000_000)
    }

    public func percentile(_ fraction: Double) -> Double? {
        guard !milliseconds.isEmpty, fraction.isFinite, (0...1).contains(fraction) else { return nil }
        let ordered = milliseconds.sorted()
        return ordered[max(0, Int(ceil(fraction * Double(ordered.count))) - 1)]
    }
}
