import Foundation
import YingchuiProtocol

struct PadFrameReceiveTiming: Sendable {
    let firstCallback: UInt64
    var lastCallback: UInt64
    var firstSystemReceive: UInt64?
    var lastSystemReceive: UInt64?
    var maximumCallbackDelay: UInt64?
    var assembledAt: UInt64?
    var deliveredAt: UInt64?
}

struct PadFrameReceiveTimingTracker {
    private var frames: [UInt32: PadFrameReceiveTiming] = [:]
    mutating func packet(_ id: UInt32, callbackAt: UInt64, systemReceiveAt: UInt64?) {
        var timing = frames.removeValue(forKey: id)
        if timing == nil {
            if frames.count >= 32, let oldest = frames.min(by: { $0.value.firstCallback < $1.value.firstCallback })?.key {
                frames.removeValue(forKey: oldest)
            }
            timing = .init(firstCallback: callbackAt, lastCallback: callbackAt,
                           firstSystemReceive: systemReceiveAt.flatMap { $0 <= callbackAt ? $0 : nil })
        }
        guard var timing else { return }
        if timing.assembledAt != nil { frames[id] = timing; return }
        timing.lastCallback = max(timing.lastCallback, callbackAt)
        if let systemReceiveAt, systemReceiveAt <= callbackAt {
            if let first = timing.firstSystemReceive { timing.firstSystemReceive = min(first, systemReceiveAt) }
            timing.maximumCallbackDelay = max(timing.maximumCallbackDelay ?? 0, callbackAt - systemReceiveAt)
            timing.lastSystemReceive = max(timing.lastSystemReceive ?? systemReceiveAt, systemReceiveAt)
        }
        frames[id] = timing
    }
    mutating func assembled(_ id: UInt32, now: UInt64) { frames[id]?.assembledAt = now }
    mutating func delivered(_ id: UInt32, now: UInt64) -> PadFrameReceiveTiming? {
        guard var timing = frames.removeValue(forKey: id) else { return nil }
        timing.deliveredAt = now
        return timing
    }
}

enum PadVideoReceiveConfiguration {
    static let adaptiveRepair: Bool = {
#if DEBUG
        !ProcessInfo.processInfo.arguments.contains("--legacy-video-repair-policy")
#else
        true
#endif
    }()
}
