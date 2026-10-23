import Foundation
import YingchuiProtocol

/// 用有限的播放速度调整消化积压；保持全部采样，达到低水位后恢复原速。
struct PadAudioLatencyController {
    private(set) var rate: Float = 1
    private var lastUpdate: UInt64?

    mutating func update(bufferedMilliseconds: Double, now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Float? {
        if let previous = lastUpdate, now >= previous, now - previous < 100_000_000 { return nil }
        lastUpdate = now
        let next: Float
        if bufferedMilliseconds <= Double(AudioBufferingPolicy.settledMilliseconds) {
            next = 1
        } else if bufferedMilliseconds >= 700 {
            next = 1.12
        } else if bufferedMilliseconds >= 400 {
            next = max(rate, 1.08)
        } else if bufferedMilliseconds >= 240 {
            next = max(rate, 1.04)
        } else if bufferedMilliseconds >= 160 {
            next = max(rate, 1.02)
        } else {
            next = rate
        }
        guard next != rate else { return nil }
        rate = next
        return next
    }

    mutating func reset() { self = Self() }
}
