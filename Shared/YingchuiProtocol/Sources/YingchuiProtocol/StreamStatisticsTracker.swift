import Foundation

public struct StreamStatisticsTracker: Sendable {
    private var previous: (decoded: UInt64, dropped: UInt64)?
    public init() {}
    public mutating func reset() { previous = nil }

    public mutating func lossRate(decoded: UInt64, dropped: UInt64, networkMissing: UInt64? = nil) throws -> Double? {
        // 防止无意义的大计数进入减法和加法；正常 120 fps 连续一年也不会达到此上限。
        guard decoded <= 10_000_000_000, dropped <= 10_000_000_000 else {
            throw StreamStatisticsError.invalidCounters
        }
        guard networkMissing.map({ $0 <= dropped }) ?? true else { throw StreamStatisticsError.invalidCounters }
        // 新端只用确认的网络缺帧调节码率；等待参考帧时主动舍弃的画面不是新的网络丢失。
        // 旧端未提供该字段时保持既有统计协议。
        let dropped = networkMissing ?? dropped
        guard let previous else {
            self.previous = (decoded, dropped)
            return nil
        }
        let decodedDelta = decoded >= previous.decoded ? decoded - previous.decoded : decoded
        let droppedDelta = dropped >= previous.dropped ? dropped - previous.dropped : dropped
        guard decodedDelta <= 100_000, droppedDelta <= 100_000 else {
            throw StreamStatisticsError.invalidCounters
        }
        self.previous = (decoded, dropped)
        let total = decodedDelta + droppedDelta
        return total >= 30 ? Double(droppedDelta) / Double(total) : nil
    }
}

public enum StreamStatisticsError: LocalizedError {
    case invalidCounters
    public var errorDescription: String? { "视频统计计数无效或变化超限" }
}
