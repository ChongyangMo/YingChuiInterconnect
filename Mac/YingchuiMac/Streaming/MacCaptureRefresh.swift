import Foundation
import ScreenCaptureKit
import YingchuiProtocol

/// 这些采集对象只在 captureQueue 上使用；异步完成回调返回同一队列后才访问。
private final class CaptureRefreshContext: @unchecked Sendable {
    let filter: SCContentFilter
    let configuration: SCStreamConfiguration
    init(filter: SCContentFilter, configuration: SCStreamConfiguration) {
        self.filter = filter
        self.configuration = configuration
    }
}

extension MacScreenStreamer {
    func recordRemoteInteraction() {
        let now = DispatchTime.now().uptimeNanoseconds
        let generation = stateLock.withLock { captureGeneration }
        captureQueue.async { [weak self] in
            guard let self, self.stream != nil,
                  self.stateLock.withLock({ self.captureGeneration == generation }) else { return }
            self.captureRecoveryPolicy.recordInteraction(now: now)
        }
    }

    func startCaptureRefreshMonitor(stream: SCStream, filter: SCContentFilter,
                                    configuration: SCStreamConfiguration) {
        let identity = ObjectIdentifier(stream)
#if DEBUG
        startBenchmarkIdleCadence(stream: stream)
#endif
        let context = CaptureRefreshContext(filter: filter, configuration: configuration)
        captureRefreshTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(100), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self, let active = self.stream, ObjectIdentifier(active) == identity else { return }
            let now = DispatchTime.now().uptimeNanoseconds
#if DEBUG
            if let start = self.pipelineMetrics.windowStart, now >= start, now - start >= 2_000_000_000,
               let report = self.benchmarkMetrics.report(streamID: self.streamID,
                    seconds: Double(now - start) / 1_000_000_000, metrics: self.pipelineMetrics) {
                self.eventLog.record(report)
            }
#endif
            if let report = self.pipelineMetrics.report(streamID: self.streamID, bitRate: self.outputBitRate,
                queuedPackets: self.stateLock.withLock({ self.outstandingDatagrams }), now: now) {
                self.eventLog.record(report)
            }
            guard self.captureRecoveryPolicy.shouldRecover(lastCapture: self.videoProgress.lastCaptureUptime,
                wasComplete: self.videoProgress.captureStatus == "完整画面",
                isRecovering: self.captureRefreshInFlight,
                receiverRequestedRefresh: self.receiverRequestedCaptureRefresh
                    && self.videoProgress.captureStatus == "画面静止", now: now) else { return }
            guard self.captureRecoveryPolicy.beginRecovery(now: now) else {
                self.failCaptureRefresh("10 秒内连续三次恢复仍未稳定")
                return
            }
            self.captureRefreshInFlight = true
            self.receiverRequestedCaptureRefresh = false
            let token = UUID()
            self.captureRecoveryToken = token
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.captureRecoveryToken == token else { return }
                self.failCaptureRefresh("采集源重启超过 2 秒未完成")
            }
            self.captureRecoveryTimeout = timeout
            self.captureQueue.asyncAfter(deadline: .now() + .seconds(2), execute: timeout)
            self.eventLog.record("采集推送停顿，重启采集源并保留编码与连接：\(self.videoProgress.summary())")
            active.stopCapture { [weak self] error in
                self?.captureQueue.async { [weak self] in
                    guard let self, let current = self.stream, ObjectIdentifier(current) == identity else { return }
                    if let error {
                        self.failCaptureRefresh(error.localizedDescription)
                        return
                    }
                    self.replaceCaptureSource(context)
                }
            }
        }
        captureRefreshTimer = timer
        timer.resume()
    }

    private func replaceCaptureSource(_ context: CaptureRefreshContext) {
        do {
            let next = SCStream(filter: context.filter, configuration: context.configuration, delegate: self)
            try next.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
            if capturesAudio { try next.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue) }
            stream = next
            requestKeyFrame()
            let identity = ObjectIdentifier(next)
            next.startCapture { [weak self] error in
                self?.captureQueue.async { [weak self] in
                    guard let self, let current = self.stream, ObjectIdentifier(current) == identity else { return }
                    if let error {
                        self.failCaptureRefresh(error.localizedDescription)
                        return
                    }
                    self.captureRefreshInFlight = false
                    self.captureRecoveryToken = nil
                    self.captureRecoveryTimeout?.cancel()
                    self.captureRecoveryTimeout = nil
                    self.eventLog.record("采集源已重新启动，视频流与控制连接保持不变")
                    self.startCaptureRefreshMonitor(stream: current, filter: context.filter, configuration: context.configuration)
                }
            }
        } catch { failCaptureRefresh(error.localizedDescription) }
    }

    private func failCaptureRefresh(_ detail: String) {
        let message = "恢复屏幕采集失败：\(detail)"
        eventLog.record(message)
        stoppedHandler?(message, .capture)
        stopOnCaptureQueue()
    }
}
