import Foundation
import YingchuiProtocol

extension PadConnectionModel {
    func handleVideoConfiguration(_ message: WireMessage) {
        guard wantsStreaming, videoConfigurationPending, videoRequestID.value == message.id else {
            eventLog.record("已拒绝过期或未请求的视频配置")
            return
        }
        guard let configuredRequest = requestedDisplayConfiguration,
              let displayState = message.displayState, displayState.isValid,
              displayState.mode != .extended || displayState.placement == configuredRequest.displayPlacement,
              let streamID = message.streamID,
              let codec = message.codec.flatMap(VideoCodec.init(rawValue:)),
              requestedVideoCapabilities.value.contains(where: { $0.codec == codec.rawValue }),
              let videoWidth = message.width,
              let videoHeight = message.height,
              (2...VideoOutputSizingPolicy.maximumSide).contains(videoWidth),
              (2...VideoOutputSizingPolicy.maximumSide).contains(videoHeight),
              let frameRate = message.frameRate, (15...configuredRequest.frameRate).contains(frameRate),
              let encodedParameterSets = message.parameterSets,
              let encodedVideoKey = message.videoKey,
              let videoKey = Data(base64Encoded: encodedVideoKey),
              videoKey.count == 32 else {
            finishStreamingFailure("Mac 返回了无效的视频配置")
            return
        }
        guard (message.supportsCursor == true) == (message.cursorState != nil),
              message.cursorState?.isValid != false else {
            finishStreamingFailure("Mac 独立光标配置无效")
            return
        }
        let parameterSets = encodedParameterSets.compactMap { Data(base64Encoded: $0) }
        guard parameterSets.count == encodedParameterSets.count else {
            finishStreamingFailure("视频参数集损坏")
            return
        }
        eventLog.record(
            "收到 Mac 视频配置：流 \(streamID.uuidString)，\(videoWidth)×\(videoHeight) @ \(message.frameRate ?? 0) fps，参数集 \(parameterSets.count) 个"
        )
        let startup = videoStartupTrace.value
        startup?.mark("收到视频配置")
        videoConfigurationDeadline?.cancel()
        videoConfigurationDeadline = nil
        videoConfigurationPending = false
        activeStreamID = streamID
        Task { @MainActor [weak self] in
            guard let self, self.wantsStreaming, self.videoRequestID.value == message.id,
                  self.activeStreamID == streamID else { return }
            do {
                self.activeVideoCodec.set(codec)
                try self.videoRenderer.configure(streamID: streamID, parameterSets: parameterSets, codec: codec)
                try self.videoRenderer.cursor.configure(streamID: streamID, state: message.cursorState)
                self.eventLog.record(message.cursorState == nil ? "当前主机使用视频内光标" : "独立光标已启用：本地即时定位，系统确认后校正")
                self.videoRenderer.startupTrace = startup
                startup?.mark("解码器创建完成")
                self.previousStatistics = nil
                self.lastVideoStatisticsUptime = nil
                self.streamMetrics.configure(streamID: streamID, width: videoWidth, height: videoHeight,
                    decodedFrames: self.playbackStatistics.snapshot().decodedFrames)
                self.videoStallPolicy = PadVideoStallPolicy()
                self.videoStallPolicy.recordProgress()
                // 解码器先就绪，再允许接收端认证并交付已暂存的首帧。
                self.networkQueue.async { [weak self] in
                    guard let self, self.wantsStreaming, self.videoRequestID.value == message.id,
                          self.activeStreamID == streamID else { return }
                    self.videoReceiver.expect(streamID: streamID, videoKey: videoKey,
                        supportsRepair: message.supportsVideoRepair == true)
                    if self.audioRequested.value { self.audioReceiver.expect(streamID: streamID, key: videoKey) }
                }
                self.activeDisplayState = displayState
                self.displayModeChanging = self.streamRequest != configuredRequest
                self.eventLog.record("显示模式已确认：\(displayState.mode.title)")
                self.isStreaming = true
                self.videoAspectRatio = Double(videoWidth) / Double(videoHeight)
                self.videoResolutionText = "\(videoWidth)×\(videoHeight) · 目标 \(message.frameRate ?? 0) 帧/秒"
                self.streamStatusText = "\(codec.title) 低延迟画面已就绪"
            } catch {
                self.eventLog.record("视频解码器配置失败：\(error.localizedDescription)")
                self.streamStatusText = "视频配置失败：\(error.localizedDescription)"
                self.networkQueue.async { [weak self] in
                    guard let self, self.videoRequestID.value == message.id else { return }
                    self.disableHEVC(reason: error.localizedDescription)
                    self.scheduleStreamRecoveryAfterFailure(reason: "解码器配置失败：\(error.localizedDescription)")
                }
            }
        }
    }
}
