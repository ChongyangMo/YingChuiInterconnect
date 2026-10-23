import Foundation
import YingchuiProtocol

struct MacVideoPipelineMetrics {
    var complete = 0, idle = 0, encoded = 0, encoderDrops = 0, sendDrops = 0
    var preEncodeDrops = 0, maximumPendingEncodes = 0
    var newCaptureSubmissions = 0, repeatedSubmissions = 0
    var encodedBytes = 0, maximumFrameBytes = 0, maximumQueuedPackets = 0
    var captureAge = VideoTimingStatistics()
    var captureInterval = VideoTimingStatistics()
    var encode = VideoTimingStatistics()
    var callbackQueue = VideoTimingStatistics()
    var packetize = VideoTimingStatistics()
    var pacingWait = VideoTimingStatistics()
    var pacingDrain = VideoTimingStatistics()
    var networkSubmit = VideoTimingStatistics()
    private var lastCapture: UInt64?
    private var intervalStart: UInt64?
    var windowStart: UInt64? { intervalStart }

    mutating func capture(isIdle: Bool, ageNanoseconds: UInt64?, now: UInt64) {
        if isIdle { idle += 1 } else { complete += 1 }
        if let ageNanoseconds { captureAge.record(ageNanoseconds) }
        if let lastCapture { captureInterval.record(from: lastCapture, to: now) }
        lastCapture = now
        if intervalStart == nil { intervalStart = now }
    }

    mutating func report(streamID: UUID, bitRate: Int, queuedPackets: Int, now: UInt64) -> String? {
        maximumQueuedPackets = max(maximumQueuedPackets, queuedPackets)
        guard let start = intervalStart, now >= start, now - start >= 2_000_000_000 else { return nil }
        let seconds = Double(now - start) / 1_000_000_000
        let report = "电脑视频分段：流 \(streamID)，窗口 \(String(format: "%.2f", seconds)) 秒，变化/静止/编码 \(complete)/\(idle)/\(encoded) 帧，编码前暂缓尝试 \(preEncodeDrops) 次，在途编码峰值 \(maximumPendingEncodes)，编码丢帧/发送拒绝 \(encoderDrops)/\(sendDrops)，实际编码 \(String(format: "%.2f", Double(encodedBytes) * 8 / seconds / 1_000_000)) 兆比特每秒，目标 \(bitRate)，最大帧 \(maximumFrameBytes) 字节，待发包峰值 \(maximumQueuedPackets)；采集间隔[\(captureInterval.summary)]，采集样本年龄[\(captureAge.summary)]，硬件编码[\(encode.summary)]，编码回调排队[\(callbackQueue.summary)]，分片加密[\(packetize.summary)]，发送前排队[\(pacingWait.summary)]，整帧提交[\(pacingDrain.summary)]，网络提交回调[\(networkSubmit.summary)]"
        let previousCapture = lastCapture
        self = Self()
        intervalStart = now
        lastCapture = previousCapture
        return report
    }
}
