#if DEBUG
import Foundation
import ScreenCaptureKit
import YingchuiProtocol

extension MacScreenStreamer {
    func startBenchmarkIdleCadence(stream: SCStream) {
        benchmarkIdleTimer?.cancel()
        benchmarkIdleTimer = nil
        guard let rate = benchmarkMetrics.settings?.idleFrameRate else { return }
        let identity = ObjectIdentifier(stream)
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + .milliseconds(17),
                       repeating: .nanoseconds(1_000_000_000 / rate), leeway: .microseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self, let active = self.stream, ObjectIdentifier(active) == identity,
                  self.videoProgress.captureStatus == "画面静止",
                  let lastCallback = self.videoProgress.lastCaptureUptime,
                  let image = self.lastCaptureImage else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            // 只在采集器持续确认静止时重复真实像素。采集中断或挂起后立刻停止，
            // 不更新采集进展，也不把重复图像标成新的变化帧。
            guard now >= lastCallback, now - lastCallback <= 100_000_000,
                  now >= self.benchmarkLastSubmission,
                  now - self.benchmarkLastSubmission >= 12_000_000 else { return }
            let keyFrame = self.stateLock.withLock {
                let value = self.forceNextKeyFrame
                self.forceNextKeyFrame = false
                return value
            }
            self.encodeCapturedImage(image, forceKeyFrame: keyFrame)
        }
        benchmarkIdleTimer = timer
        timer.resume()
        eventLog.record("静止帧率对照：持续编码真实静止画面，目标 \(rate) 帧/秒")
    }
}
#endif
