import Foundation

public struct PeerClockEstimate: Sendable {
    public let offsetMilliseconds: Double
    public let minimumRoundTripMilliseconds: Double
    public let sampleCount: Int
}

/// 最多保留十六个、三十秒内的真实样本，避免排队较长的回包拉动时钟偏移。
public struct PeerClockEstimator: Sendable {
    private struct Sample: Sendable {
        let offset: Double
        let roundTrip: Double
        let receivedAt: UInt64
    }
    private var samples: [Sample] = []
    public private(set) var estimate: PeerClockEstimate?
    public init() {}

    public mutating func record(sentWallMilliseconds: UInt64, receivedWallMilliseconds: UInt64,
        peerWallMilliseconds: UInt64, roundTripMilliseconds: Double, receivedAtUptime: UInt64) {
        samples.removeAll { receivedAtUptime < $0.receivedAt || receivedAtUptime - $0.receivedAt > 30_000_000_000 }
        updateEstimate()
        guard roundTripMilliseconds.isFinite, roundTripMilliseconds > 0,
              roundTripMilliseconds < 2_000, peerWallMilliseconds > 0 else { return }
        let wallElapsed = Double(receivedWallMilliseconds) - Double(sentWallMilliseconds)
        // 本地时钟跳变时，旧偏移已无意义；下一次正常往返重新校准。
        guard abs(wallElapsed - roundTripMilliseconds) <= 10 else { reset(); return }
        samples.append(Sample(offset: Double(peerWallMilliseconds)
            - (Double(sentWallMilliseconds) + Double(receivedWallMilliseconds)) / 2,
            roundTrip: roundTripMilliseconds, receivedAt: receivedAtUptime))
        if samples.count > 16 { samples.removeFirst(samples.count - 16) }
        updateEstimate()
    }

    private mutating func updateEstimate() {
        guard let best = samples.min(by: {
            $0.roundTrip == $1.roundTrip ? $0.receivedAt > $1.receivedAt : $0.roundTrip < $1.roundTrip
        }) else { estimate = nil; return }
        estimate = PeerClockEstimate(offsetMilliseconds: best.offset,
            minimumRoundTripMilliseconds: best.roundTrip, sampleCount: samples.count)
    }

    public mutating func reset() { samples.removeAll(keepingCapacity: true); estimate = nil }
}
