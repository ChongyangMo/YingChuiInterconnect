#if DEBUG
import Foundation
import YingchuiProtocol

struct PadVideoBenchmarkMetrics {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--video-benchmark")
    var age = VideoBenchmarkSamples()
    var gap = VideoBenchmarkSamples()
    var decode = VideoBenchmarkSamples()
    var clockGap = VideoBenchmarkSamples()
    var start: UInt64?
    private var frames: [[String: Any]] = []
    mutating func input() {
        guard Self.enabled, frames.count < 1_024 else { return }
        frames.append(["stage": "input", "time": Date().timeIntervalSince1970])
    }

    mutating func frame(_ stage: String, _ frame: CompletedVideoFrame, uptime: UInt64? = nil, receiveTiming: PadFrameReceiveTiming? = nil,
                        mainDeliveredAt: UInt64? = nil) {
        guard Self.enabled, frames.count < 1_024 else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = uptime.map { now >= $0 ? Double(now - $0) / 1_000_000_000 : 0 } ?? 0
        let wall = Date().timeIntervalSince1970
        var record: [String: Any] = ["stage": stage, "time": wall - elapsed,
                       "frameID": frame.frameID, "sourceMicroseconds": frame.presentationTimeMicroseconds]
        if let mainDeliveredAt { record["mainDeliveredTime"] = wall - Double(now >= mainDeliveredAt ? now - mainDeliveredAt : 0) / 1_000_000_000 }
        if let timing = receiveTiming {
            func stamp(_ uptime: UInt64) -> Double { wall - Double(now >= uptime ? now - uptime : 0) / 1_000_000_000 }
            record["firstPacketCallbackTime"] = stamp(timing.firstCallback)
            record["lastPacketCallbackTime"] = stamp(timing.lastCallback)
            if let system = timing.firstSystemReceive { record["firstSystemPacketTime"] = stamp(system) }
            if let system = timing.lastSystemReceive { record["lastSystemPacketTime"] = stamp(system) }
            if let delay = timing.maximumCallbackDelay { record["maximumSystemToCallbackMilliseconds"] = Double(delay) / 1_000_000 }
            if let assembled = timing.assembledAt { record["assembledTime"] = stamp(assembled) }
            if let delivered = timing.deliveredAt { record["deliveredTime"] = stamp(delivered) }
        }
        frames.append(record)
    }

    mutating func clock(_ gap: UInt64) {
        guard Self.enabled, frames.count < 1_024 else { return }
        frames.append(["stage": "clock", "time": Date().timeIntervalSince1970,
                       "gapMilliseconds": Double(gap) / 1_000_000])
    }

    mutating func presentation(_ frame: CompletedVideoFrame, queuedAt: UInt64, deliveredAt: UInt64, depth: Int,
                               immediateInteraction: Bool = false) {
        guard Self.enabled, frames.count < 1_024, deliveredAt >= queuedAt else { return }
        frames.append(["stage": "presentationDequeued", "time": Date().timeIntervalSince1970,
                       "frameID": frame.frameID, "queueWaitMilliseconds": Double(deliveredAt - queuedAt) / 1_000_000,
                       "queueDepth": depth, "immediateInteraction": immediateInteraction])
    }

    mutating func decodeTiming(_ frame: CompletedVideoFrame, timing: VideoFrameDecodeTiming) {
        guard Self.enabled, frames.count < 1_024 else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let wall = Date().timeIntervalSince1970
        func stamp(_ uptime: UInt64) -> Double { wall - Double(now >= uptime ? now - uptime : 0) / 1_000_000_000 }
        frames.append(["stage": "decodeTiming", "time": stamp(timing.deliveredAt), "frameID": frame.frameID,
                       "preparationTime": stamp(timing.preparationStartedAt), "submittedTime": stamp(timing.submittedAt),
                       "callbackTime": stamp(timing.callbackAt), "deliveredTime": stamp(timing.deliveredAt),
                       "pendingDecodeCount": timing.pendingCount])
    }

    mutating func report(streamID: UUID, decoded: Int, presented: Int, coalesced: Int, layersNotReady: Int,
                         maximumPending: Int, clockOffset: Double?, now: UInt64, clockEstimate: PeerClockEstimate? = nil) -> String? {
        defer {
            age = .init(); gap = .init(); decode = .init(); clockGap = .init(); start = now
            frames.removeAll(keepingCapacity: true)
        }
        guard Self.enabled, let start, now > start else { return nil }
        var record: [String: Any] = [
            "side": "ipad", "streamID": streamID.uuidString,
            "adaptiveRepair": PadVideoReceiveConfiguration.adaptiveRepair,
            "presentationAgeLimited": PadVideoPresentationConfiguration.ageLimited,
            "immediateInteractionPresentation": PadVideoPresentationConfiguration.immediateInteraction,
            "endTime": Date().timeIntervalSince1970,
            "seconds": Double(now - start) / 1_000_000_000,
            "decoded": decoded, "layersNotReady": layersNotReady,
            "presented": presented, "coalesced": coalesced,
            "maximumPending": maximumPending,
            "ageMilliseconds": age.milliseconds, "gapMilliseconds": gap.milliseconds,
            "decodeMilliseconds": decode.milliseconds, "presentationClockGapMilliseconds": clockGap.milliseconds,
            "frameSamples": frames
        ]
        if let clockOffset {
            record["hostEndTime"] = Date().timeIntervalSince1970 + clockOffset / 1_000
            record["clockOffsetMilliseconds"] = clockOffset
        }
        if let clockEstimate {
            record["clockMinimumRoundTripMilliseconds"] = clockEstimate.minimumRoundTripMilliseconds
            record["clockSampleCount"] = clockEstimate.sampleCount
        }
        VideoBenchmarkFrameArchive.shared.append(record, streamID: streamID)
        record.removeValue(forKey: "frameSamples")
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "视频性能对比：\(json)"
    }
}
#endif
