import Foundation
import YingchuiProtocol

extension MacScreenStreamer {
    func finishEncode(_ ticket: UUID) {
        guard encodeAdmission.complete(ticket) else { return }
        if captureRevision > submittedRevision || stateLock.withLock({ forceNextKeyFrame }) {
            encodeReplayWorkItem?.cancel()
            encodeReplayWorkItem = nil
            encodeReplayToken = nil
            // 编码槽位已经归还，立即消费最新真实采集帧，避免再人为等待四毫秒。
            replayLatestCapture()
        }
    }

    func scheduleEncodeReplay() {
        guard encodeReplayWorkItem == nil, stream != nil else { return }
        let generation = stateLock.withLock { captureGeneration }
        let token = UUID()
        encodeReplayToken = token
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.encodeReplayToken == token,
                  self.stateLock.withLock({ self.captureGeneration == generation }) else { return }
            self.encodeReplayWorkItem = nil
            self.encodeReplayToken = nil
            self.replayLatestCapture()
        }
        encodeReplayWorkItem = item
        captureQueue.asyncAfter(deadline: .now() + .milliseconds(4), execute: item)
    }

    private func replayLatestCapture() {
        let now = DispatchTime.now().uptimeNanoseconds
        // 只补发刚刚真实采集的最后变化，不能在采集中断后不断编码旧图冒充进展。
        guard stream != nil, let image = lastCaptureImage,
              now >= lastImageCaptureUptime, now - lastImageCaptureUptime <= 250_000_000 else { return }
        let keyFrame = stateLock.withLock { forceNextKeyFrame }
        guard captureRevision > submittedRevision || keyFrame else { return }
        if keyFrame { stateLock.withLock { forceNextKeyFrame = false } }
        encodeCapturedImage(image, forceKeyFrame: keyFrame)
    }
}
