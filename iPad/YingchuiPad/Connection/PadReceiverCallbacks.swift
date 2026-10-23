import Foundation
import YingchuiProtocol

extension PadConnectionModel {
    @MainActor
    func configureReceiverCallbacks() {
        videoReceiver.onReady = { [weak self] port, generation in
            self?.networkQueue.async { [weak self] in
                guard let self, self.wantsStreaming, self.videoReceiverGeneration.value == generation,
                      self.connection != nil else { return }
                self.activeVideoPort = port
                self.sendStreamWhenPortsReady()
            }
        }
        audioReceiver.onReady = { [weak self] port, generation in
            self?.networkQueue.async { [weak self] in
                guard let self, self.wantsStreaming, self.videoReceiverGeneration.value == generation else { return }
                self.activeAudioPort = port
                self.sendStreamWhenPortsReady()
            }
        }
        audioReceiver.onFailure = { [weak self] status, generation in
            self?.networkQueue.async { [weak self] in
                guard let self, self.videoReceiverGeneration.value == generation else { return }
                self.finishStreamingFailure(status)
            }
        }
        videoReceiver.onFrame = { [weak self] frame, receiveTiming in
            let receivedAt = DispatchTime.now().uptimeNanoseconds
            Task { @MainActor [weak self] in
                guard let self, self.wantsStreaming, self.activeStreamID == frame.streamID else { return }
                let clockEstimate = self.peerClockEstimateState.value
                self.videoRenderer.pipelineMetrics.input(frame, receivedAt: receivedAt,
                    clockOffset: clockEstimate?.offsetMilliseconds, receiveTiming: receiveTiming,
                    clockEstimate: clockEstimate)
                self.videoStartupTrace.value?.mark("首个完整帧交付主线程", detail: "帧 \(frame.frameID)")
                let clientNowMicroseconds = Date().timeIntervalSince1970 * 1_000_000
                self.latestVideoLatencyMilliseconds = nil
                if let clockEstimate {
                    let serverNowMicroseconds = clientNowMicroseconds + clockEstimate.offsetMilliseconds * 1_000
                    let latency = (serverNowMicroseconds - Double(frame.presentationTimeMicroseconds)) / 1_000
                    if latency.isFinite, latency >= 0, latency < 60_000 {
                        self.latestVideoLatencyMilliseconds = latency
                        self.videoLatencySamples.append(latency)
                    }
                } else { self.videoLatencySamples.reset() }
                let frameArrivalUptime = DispatchTime.now().uptimeNanoseconds
                let interactionLatency = self.pendingVisualControlState.mutate { state -> Double? in
                    guard let pending = state,
                          frame.presentationTimeMicroseconds >= pending.executedAtMacMicroseconds,
                          frameArrivalUptime >= pending.sentAtUptimeNanoseconds else { return nil }
                    state = nil
                    return Double(frameArrivalUptime - pending.sentAtUptimeNanoseconds) / 1_000_000
                }
                if let interactionLatency {
                    self.latestInteractionToVideoFrameMilliseconds = interactionLatency
                }
                do {
                    try self.videoRenderer.enqueue(frame)
                } catch VideoRendererError.missingInitialKeyFrame {
                    self.playbackStatistics.recordDroppedFrame()
                    self.streamStatusText = VideoRendererError.missingInitialKeyFrame.localizedDescription
                } catch {
                    self.eventLog.record(
                        "视频帧送入解码器失败：帧 \(frame.frameID)，长度 \(frame.accessUnit.count) 字节，原因：\(error.localizedDescription)"
                    )
                    self.playbackStatistics.recordDroppedFrame()
                    self.streamStatusText = "视频解码失败：\(error.localizedDescription)"
                    self.networkQueue.async { [weak self] in self?.disableHEVC(reason: error.localizedDescription); self?.scheduleStreamRecoveryAfterFailure(reason: "视频帧提交解码失败：\(error.localizedDescription)") }
                }
            }
        }
        videoReceiver.onStatus = { [weak self] status in
            guard let self, let generation = self.videoReceiverGeneration.value else { return }
            Task { @MainActor [weak self] in
                guard let self, self.wantsStreaming, self.videoReceiverGeneration.value == generation else { return }
                self.streamStatusText = status
            }
        }
        videoReceiver.onStatistics = { [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.handleVideoStatistics(snapshot)
            }
        }
        videoReceiver.onNeedsVideoRepair = { [weak self] streamID, request in
            self?.networkQueue.async { [weak self] in
                guard let self, self.wantsStreaming, self.activeStreamID == streamID,
                      let connection = self.connection else { return }
                self.send(WireMessage(kind: .keyframeRequest, streamID: streamID, videoRepair: request), over: connection)
            }
        }
        videoReceiver.onNeedsKeyFrame = { [weak self] in
            Task { @MainActor [weak self] in
                self?.requestKeyFrame()
            }
        }
        videoReceiver.onRecoverableFailure = { [weak self] status in
            guard let self, let generation = self.videoReceiverGeneration.value else { return }
            self.networkQueue.async { [weak self] in
                guard let self, self.videoReceiverGeneration.value == generation else { return }
                self.scheduleStreamRecoveryAfterFailure(reason: status)
            }
        }
        videoRenderer.onNeedsKeyFrame = { [weak self] in
            self?.eventLog.record("视频起始关键帧缺失，已请求 Mac 补发关键帧")
            self?.requestKeyFrame()
        }
        videoRenderer.onFailure = { [weak self] status in
            guard let self else { return }
            self.playbackStatistics.recordDroppedFrame()
            self.eventLog.record("视频播放失败：\(status)")
            self.streamStatusText = status
            self.networkQueue.async { [weak self] in self?.disableHEVC(reason: status); self?.scheduleStreamRecoveryAfterFailure(reason: status) }
        }
        videoRenderer.onFrameDecoded = { [weak self] frameID in
            guard let self else { return }
            self.playbackStatistics.recordDecodedFrame()
            self.videoStallPolicy.recordProgress()
            if !self.videoIsPlaying {
                self.videoStartupTrace.value?.mark("首帧解码完成", detail: "帧 \(frameID)")
                self.eventLog.record("首帧已完成解码：帧 \(frameID)")
            }
            if !self.videoIsPlaying { self.videoIsPlaying = true }
            if self.streamStatusText == VideoRendererError.missingInitialKeyFrame.localizedDescription {
                self.streamStatusText = "\(self.activeVideoCodec.value.title) 低延迟画面已就绪"
            }
            if self.enterFullScreenAfterConnection {
                self.enterFullScreenAfterConnection = false
                self.shouldPresentFullScreen = true
            }
        }

    }
}
