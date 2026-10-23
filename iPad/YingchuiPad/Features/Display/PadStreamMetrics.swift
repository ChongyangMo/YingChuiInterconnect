import Foundation
import Observation

/// 独立于连接模型发布，统计刷新只影响小型信息条。
@MainActor @Observable
final class PadStreamMetrics {
    static let visibilityKey = "YingchuiShowStreamMetrics"
    private(set) var resolution: String?
    private(set) var framesPerSecond: Double?
    private(set) var audioMilliseconds: Double?
    private(set) var updatedAt: UInt64?
    private(set) var roundTripMilliseconds: Double?
    private(set) var pingAt: UInt64?
    @ObservationIgnored private var streamID: UUID?
    @ObservationIgnored private var baseline: (frames: UInt64, time: UInt64)?

    func configure(streamID: UUID, width: Int, height: Int, decodedFrames: UInt64,
                   now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        self.streamID = streamID
        resolution = width > 0 && height > 0 ? "\(width)×\(height)" : nil
        framesPerSecond = nil
        audioMilliseconds = nil
        updatedAt = nil
        baseline = (decodedFrames, now)
    }

    func sample(streamID: UUID, decodedFrames: UInt64, audioMilliseconds: Double?,
                now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        guard self.streamID == streamID, let baseline, now > baseline.time else { return }
        // 实际经过时间内的解码增量；计数重置时重新取样，不显示假帧率。
        framesPerSecond = decodedFrames >= baseline.frames
            ? Double(decodedFrames - baseline.frames) * 1_000_000_000 / Double(now - baseline.time) : nil
        self.baseline = (decodedFrames, now)
        self.audioMilliseconds = Self.validMilliseconds(audioMilliseconds)
        updatedAt = now
    }

    func recordRoundTrip(_ milliseconds: Double, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        roundTripMilliseconds = Self.validMilliseconds(milliseconds)
        pingAt = now
    }

    func reset() {
        streamID = nil
        baseline = nil
        resolution = nil
        framesPerSecond = nil
        audioMilliseconds = nil
        updatedAt = nil
        roundTripMilliseconds = nil
        pingAt = nil
    }

    func isFresh(_ timestamp: UInt64?, now: UInt64) -> Bool {
        guard let timestamp, now >= timestamp else { return false }
        return now - timestamp < 3_000_000_000
    }

    private static func validMilliseconds(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}
