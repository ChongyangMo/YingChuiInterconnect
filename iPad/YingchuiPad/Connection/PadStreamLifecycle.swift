import Foundation
import YingchuiProtocol

extension PadConnectionModel {
    @MainActor
    func startVideoReceiver() {
        guard wantsStreaming else { return }
        receiverPreparationStarted.set(DispatchTime.now().uptimeNanoseconds)
        let generation = UUID()
        videoReceiverGeneration.set(generation)
        let audioEnabled = isAudioEnabled
        audioRequested.set(audioEnabled)
        networkQueue.async { [weak self] in
            guard let self, self.videoReceiverGeneration.value == generation else { return }
            self.activeVideoPort = nil
            self.activeAudioPort = nil
            if audioEnabled { self.audioReceiver.start(generation: generation) }
            self.videoReceiver.start(generation: generation)
        }
    }

    /// 在网络队列中停止全部视频资源，显式失败不再触发自动重试。
    func finishStreamingFailure(_ reason: String) {
        wantsStreaming = false
        videoReceiverGeneration.set(nil)
        videoRequestID.set(nil)
        videoConfigurationDeadline?.cancel()
        videoConfigurationDeadline = nil
        requestedDisplayConfiguration = nil
        videoConfigurationPending = false
        activeStreamID = nil
        activeVideoPort = nil
        streamReconfigureWorkItem?.cancel()
        streamReconfigureWorkItem = nil
        streamRecoveryWorkItem?.cancel()
        streamRecoveryWorkItem = nil
        audioReceiver.stop()
        activeAudioPort = nil
        videoReceiver.stop()
        if let connection { send(WireMessage(kind: .streamStop), over: connection) }
        let epoch = connectionEpoch.value
        eventLog.record(reason)
        Task { @MainActor [weak self] in
            guard let self, self.connectionEpoch.value == epoch, !self.wantsStreaming else { return }
            self.activeDisplayState = nil
            self.displayModeChanging = false
            self.isStreaming = false
            self.streamMetrics.reset()
            self.videoIsPlaying = false
            self.videoRenderer.reset()
            self.videoResolutionText = "—"
            self.videoAspectRatio = nil
            self.previousStatistics = nil
            self.videoStallPolicy = PadVideoStallPolicy()
            self.streamStatusText = reason
            self.statusText = reason
        }
    }
}
