import Foundation
import YingchuiProtocol

@MainActor
final class PadVideoPipelineMetrics {
    let log = DiagnosticEventLog(subsystem: "com.yingchui.interconnect.pad", category: "视频显示诊断")
    var streamID: UUID?
    var mainWait = VideoTimingStatistics()
    var prepare = VideoTimingStatistics()
    var decode = VideoTimingStatistics()
    var decodeMainWait = VideoTimingStatistics()
    var display = VideoTimingStatistics()
    var displayGap = VideoTimingStatistics()
    var presentationClockGap = VideoTimingStatistics()
    var presentationWait = VideoTimingStatistics()
    var maximumPresentationDepth = 0
    var sourceGap = VideoTimingStatistics()
    var estimatedAge = VideoTimingStatistics()
    var decoded = 0, presented = 0, coalesced = 0, layersNotReady = 0, maximumPending = 0
    var onReport: (() -> Void)?
    private var lastDisplay: UInt64?
    private var lastPTS: UInt64?
    private var clockOffset: Double?
    private var clockEstimate: PeerClockEstimate?
    private var timer: Task<Void, Never>?
#if DEBUG
    var benchmark = PadVideoBenchmarkMetrics()
#endif

    init() {
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self else { return }
                self.report()
            }
        }
    }

    deinit { timer?.cancel() }

    func input(_ frame: CompletedVideoFrame, receivedAt: UInt64, clockOffset: Double?, receiveTiming: PadFrameReceiveTiming? = nil,
               clockEstimate: PeerClockEstimate? = nil) {
        if streamID != frame.streamID { reset(); streamID = frame.streamID }
        self.clockOffset = clockOffset
        self.clockEstimate = clockEstimate
#if DEBUG
        benchmark.frame("received", frame, uptime: receivedAt, receiveTiming: receiveTiming,
            mainDeliveredAt: DispatchTime.now().uptimeNanoseconds)
#endif
        mainWait.record(from: receivedAt, to: DispatchTime.now().uptimeNanoseconds)
    }

    func displayed(_ frame: CompletedVideoFrame, at now: UInt64, layerCount: Int) {
        presented += 1
#if DEBUG
        benchmark.frame("presented", frame, uptime: now)
#endif
#if DEBUG
        if PadVideoBenchmarkMetrics.enabled {
            if benchmark.start == nil { benchmark.start = now }
            if let lastDisplay { benchmark.gap.record(from: lastDisplay, to: now) }
        }
#endif
        if let lastDisplay { displayGap.record(from: lastDisplay, to: now) }
        if let lastPTS, frame.presentationTimeMicroseconds >= lastPTS,
           frame.presentationTimeMicroseconds - lastPTS <= 60_000_000 {
            sourceGap.record((frame.presentationTimeMicroseconds - lastPTS) * 1_000)
        }
        if let clockOffset {
            let age = Date().timeIntervalSince1970 * 1_000_000 + clockOffset * 1_000 - Double(frame.presentationTimeMicroseconds)
            if age >= 0 && age < 60_000_000 { estimatedAge.record(UInt64(age * 1_000)) }
#if DEBUG
            if PadVideoBenchmarkMetrics.enabled { benchmark.age.record(milliseconds: age / 1_000) }
#endif
        }
        lastDisplay = now
        lastPTS = frame.presentationTimeMicroseconds
        if layerCount == 0 { layersNotReady += 1 }
    }

    func report() {
        guard let streamID else { return }
#if DEBUG
        if let report = benchmark.report(streamID: streamID, decoded: decoded, presented: presented, coalesced: coalesced,
            layersNotReady: layersNotReady, maximumPending: maximumPending,
            clockOffset: clockOffset, now: DispatchTime.now().uptimeNanoseconds, clockEstimate: clockEstimate) {
            log.record(report)
        }
#endif
        log.record("平板显示分段：流 \(streamID)，实际解码 \(decoded) 帧，显示提交 \(presented) 帧，合并过期画面 \(coalesced) 帧，解码待处理峰值 \(maximumPending)，显示层未就绪 \(layersNotReady)；接收转主线程[\(mainWait.summary)]，准备解码[\(prepare.summary)]，硬件解码[\(decode.summary)]，解码回主线程[\(decodeMainWait.summary)]，显示提交[\(display.summary)]，显示提交间隔[\(displayGap.summary)]，源帧间隔[\(sourceGap.summary)]，校时后提交年龄估算[\(estimatedAge.summary)]")
        log.record("显示时钟分段：流 \(streamID)，活动刷新间隔[\(presentationClockGap.summary)]")
        log.record("显示队列分段：流 \(streamID)，解码后排队[\(presentationWait.summary)]，已解码排队峰值 \(maximumPresentationDepth)")
        clearWindow()
        onReport?()
    }

    func reset() {
        streamID = nil; lastDisplay = nil; lastPTS = nil; clockOffset = nil; clockEstimate = nil
#if DEBUG
        benchmark = PadVideoBenchmarkMetrics()
#endif
        clearWindow()
    }

    private func clearWindow() {
        mainWait = .init(); prepare = .init(); decode = .init(); decodeMainWait = .init()
        display = .init(); displayGap = .init(); presentationClockGap = .init(); sourceGap = .init(); estimatedAge = .init()
        decoded = 0; presented = 0; coalesced = 0; layersNotReady = 0; maximumPending = 0
        presentationWait = .init(); maximumPresentationDepth = 0
    }
}
