#if DEBUG
import Foundation
import YingchuiProtocol

struct MacVideoBenchmarkMetrics {
    var settings: MacVideoBenchmarkSettings?
    var actualLowLatencyRateControl: Bool?
    var encode = VideoBenchmarkSamples()
    private var frames: [[String: Any]] = []

    mutating func submitted(source: UInt64, revision: UInt64, imageAge: Double) {
        guard settings != nil, frames.count < 1_024 else { return }
        frames.append(["stage": "submitted", "time": Date().timeIntervalSince1970,
                       "sourceMicroseconds": source, "captureRevision": revision,
                       "imageAgeMilliseconds": imageAge])
    }

    mutating func capture(idle: Bool, age: Double, revision: UInt64) {
        guard settings != nil, frames.count < 1_024, age.isFinite, abs(age) < 60 else { return }
        frames.append(["stage": "capture", "time": Date().timeIntervalSince1970,
                       "idle": idle, "ageMilliseconds": age * 1_000, "captureRevision": revision])
    }

    mutating func encoded(id: UInt32, source: UInt64, keyFrame: Bool, bytes: Int, packets: Int, copies: Int) {
        guard settings != nil, frames.count < 1_024 else { return }
        frames.append(["stage": "encoded", "time": Date().timeIntervalSince1970, "frameID": id,
                       "sourceMicroseconds": source, "keyFrame": keyFrame, "bytes": bytes,
                       "packets": packets, "copies": copies])
    }

    mutating func sent(id: UInt32, wait: UInt64, drain: UInt64) {
        guard settings != nil, frames.count < 1_024 else { return }
        frames.append(["stage": "sent", "time": Date().timeIntervalSince1970, "frameID": id,
                       "waitMilliseconds": Double(wait) / 1_000_000, "drainMilliseconds": Double(drain) / 1_000_000])
    }

    mutating func report(streamID: UUID, seconds: Double, metrics: MacVideoPipelineMetrics) -> String? {
        defer { encode = .init(); frames.removeAll(keepingCapacity: true) }
        guard let settings else { return nil }
        var record: [String: Any] = [
            "side": "mac", "runID": settings.runID, "streamID": streamID.uuidString,
            "codec": settings.codec.rawValue, "inflight": settings.maximumPendingEncodes,
            "idleFrameRate": settings.idleFrameRate ?? 0,
            "acceleratesLargeFrames": settings.acceleratesLargeFrames ?? true,
            "endTime": Date().timeIntervalSince1970, "seconds": seconds,
            "encoded": metrics.encoded, "encodedBytes": metrics.encodedBytes,
            "completeCaptures": metrics.complete, "idleCaptures": metrics.idle,
            "newCaptureSubmissions": metrics.newCaptureSubmissions,
            "repeatedSubmissions": metrics.repeatedSubmissions,
            "encodeMilliseconds": encode.milliseconds,
            "preEncodeDeferrals": metrics.preEncodeDrops,
            "encoderDrops": metrics.encoderDrops, "sendDrops": metrics.sendDrops,
            "maximumPendingEncodes": metrics.maximumPendingEncodes,
            "maximumQueuedPackets": metrics.maximumQueuedPackets, "frameSamples": frames
        ]
        if let actualLowLatencyRateControl { record["lowLatencyRateControl"] = actualLowLatencyRateControl }
        VideoBenchmarkFrameArchive.shared.append(record, streamID: streamID)
        record.removeValue(forKey: "frameSamples")
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "视频性能对比：\(json)"
    }
}
#endif
