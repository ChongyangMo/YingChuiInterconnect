import CryptoKit
import Foundation
import Network
import Security
import UIKit
import YingchuiProtocol

extension PadConnectionModel {
    @MainActor
    func startStreaming() {
        guard !isInBackgroundState.value else { return }
        guard isPaired else {
            streamStatusText = "请先完成设备配对"
            return
        }
        guard !isStreaming else { return }
        guard let displayCapabilities = PadDisplayCapabilities.active() else {
            streamStatusText = "无法读取 iPad 屏幕分辨率与刷新率"
            return
        }
        applyDisplayCapabilities(displayCapabilities)
        videoReceiverGeneration.set(nil)
        videoRequestID.set(nil)
        wantsStreaming = true
        videoIsPlaying = false
        activeQuality = selectedQuality
        streamRequest = StreamRequest(
            quality: selectedQuality,
            viewport: viewport,
            maximumFrameRate: maximumDisplayFrameRate,
            displayMode: selectedDisplayMode,
            displayPlacement: displayPlacement
        )
        previousStatistics = nil
        streamMetrics.reset()
        videoStallPolicy = PadVideoStallPolicy()
        playbackStatistics.reset()
        videoPacketsReceived = 0
        videoFramesDecoded = 0
        videoFramesDropped = 0
        estimatedVideoLatencyMilliseconds = nil
        latestVideoLatencyMilliseconds = nil
        videoLatencyP50Milliseconds = nil
        videoLatencyP95Milliseconds = nil
        videoLatencySamples.reset()
        videoResolutionText = "正在协商"
        videoAspectRatio = nil
        activeDisplayState = nil
        displayModeChanging = true
        streamStatusText = "正在创建 UDP 视频接收端"
        isStreaming = true
        networkQueue.async { [weak self] in
            guard let self else { return }
            self.streamRecoveryPolicy.reset()
            self.streamRecoveryWorkItem?.cancel()
            self.streamRecoveryWorkItem = nil
        }
        startVideoReceiver()
    }

    @MainActor
    func refreshStreamingViewport(
        viewSize: CGSize? = nil,
        nativeScale: CGFloat? = nil
    ) {
        guard let displayCapabilities = PadDisplayCapabilities.active(
            viewSize: viewSize,
            nativeScale: nativeScale
        ) else {
            if isStreaming {
                streamStatusText = "无法读取 iPad 屏幕分辨率与刷新率"
            }
            return
        }
        let streamConfigurationChanged = displayCapabilities.viewport != viewport
            || displayCapabilities.maximumFrameRate != maximumDisplayFrameRate
        applyDisplayCapabilities(displayCapabilities)
        guard streamConfigurationChanged else { return }
        guard isStreaming else { return }
        scheduleStreamReconfiguration(quality: activeQuality, status: "正在适配屏幕")
    }

    @MainActor
    func resolutionText(for quality: StreamQualityPreset) -> String? {
        guard let resolutionViewport else { return nil }
        let dimensions = quality.dimensions(
            nativeWidth: resolutionViewport.width,
            nativeHeight: resolutionViewport.height
        )
        return "\(dimensions.width)×\(dimensions.height)"
    }

    @MainActor
    func applyDisplayCapabilities(_ capabilities: PadDisplayCapabilities) {
        videoDecodeCapabilities.set(PadVideoCapabilities.current(maximumFrameRate: capabilities.maximumFrameRate))
        viewport = capabilities.viewport
        maximumDisplayFrameRate = capabilities.maximumFrameRate
        resolutionViewport = capabilities.viewport
        let options = StreamQualityPreset.resolutionOptions(viewport: capabilities.viewport)
        resolutionOptions = options
        guard !options.contains(selectedQuality), let highestResolution = options.last else { return }
        selectedQuality = highestResolution
    }

    @MainActor
    func scheduleStreamReconfiguration(quality: StreamQualityPreset, status: String, force: Bool = false) {
        let nextRequest = StreamRequest(
            quality: quality,
            viewport: viewport,
            maximumFrameRate: maximumDisplayFrameRate,
            displayMode: selectedDisplayMode,
            displayPlacement: displayPlacement
        )
        guard force || nextRequest != streamRequest else { return }
        displayModeChanging = true
        streamRequest = nextRequest
        activeQuality = quality
        streamStatusText = status

        networkQueue.async { [weak self] in
            guard let self else { return }
            self.streamReconfigureWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self,
                      self.wantsStreaming,
                      let port = self.activeVideoPort,
                      let connection = self.connection else { return }
                self.sendStreamRequest(nextRequest, port: port, over: connection)
                self.streamReconfigureWorkItem = nil
            }
            self.streamReconfigureWorkItem = workItem
            self.networkQueue.asyncAfter(deadline: .now() + .milliseconds(350), execute: workItem)
        }
    }

    @MainActor
    func stopStreaming() {
        streamMetrics.reset()
        enterFullScreenAfterConnection = false
        shouldPresentFullScreen = false
        videoReceiverGeneration.set(nil)
        videoRequestID.set(nil)
        activeDisplayState = nil
        displayModeChanging = false
        isStreaming = false
        wantsStreaming = false
        streamStatusText = "屏幕回传已停止"
        videoResolutionText = "—"
        videoAspectRatio = nil
        estimatedVideoLatencyMilliseconds = nil
        latestVideoLatencyMilliseconds = nil
        videoLatencyP50Milliseconds = nil
        videoLatencyP95Milliseconds = nil
        videoLatencySamples.reset()
        interactionToVideoFrameMilliseconds = nil
        interactionToVideoFrameP95Milliseconds = nil
        interactionToVideoFrameSamples.reset()
        latestInteractionToVideoFrameMilliseconds = nil
        pendingVisualControlState.set(nil)
        activeStreamID = nil
        previousStatistics = nil
        videoStallPolicy = PadVideoStallPolicy()
        audioReceiver.stop()
        activeAudioPort = nil
        videoReceiver.stop()
        videoIsPlaying = false
        videoRenderer.reset()
        networkQueue.async { [weak self] in
            guard let self else { return }
            self.streamReconfigureWorkItem?.cancel()
            self.streamReconfigureWorkItem = nil
            self.streamRecoveryWorkItem?.cancel()
            self.streamRecoveryWorkItem = nil
            self.videoConfigurationDeadline?.cancel()
            self.videoConfigurationDeadline = nil
            self.requestedDisplayConfiguration = nil
            self.videoConfigurationPending = false
            self.activeVideoPort = nil
            guard let connection = self.connection else { return }
            self.send(WireMessage(kind: .streamStop), over: connection)
        }
    }

    @MainActor
    func requestKeyFrame() {
        guard isStreaming else { return }
        networkQueue.async { [weak self] in
            guard let self, let connection = self.connection else { return }
            self.send(WireMessage(kind: .keyframeRequest, streamID: self.activeStreamID), over: connection)
        }
    }

    func sendStreamRequest(
        _ request: StreamRequest,
        port: UInt16,
        over activeConnection: NWConnection
    ) {
        guard wantsStreaming, connection === activeConnection else { return }
        let requestID = UUID()
        videoRequestID.set(requestID)
        let startup = StreamStartupTrace(requestID: requestID, log: eventLog)
        videoStartupTrace.set(startup)
        let preparation = receiverPreparationStarted.mutate { value -> UInt64? in
            defer { value = nil }
            return value
        }
        let preparationDetail = preparation.map {
            "音视频接收端准备 \(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - $0) / 1_000_000)) 毫秒"
        } ?? "复用已就绪接收端"
        startup.mark("iPad 发送视频请求", detail: preparationDetail)
        videoConfigurationPending = true
        requestedDisplayConfiguration = request
        videoConfigurationDeadline?.cancel()
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.wantsStreaming, self.videoRequestID.value == requestID,
                  self.videoConfigurationPending else { return }
            self.finishStreamingFailure("Mac 应用显示配置超时")
        }
        videoConfigurationDeadline = deadline
        networkQueue.asyncAfter(deadline: .now() + .seconds(12), execute: deadline)
        eventLog.record(
            "发送视频请求：视口 \(request.viewport.width)×\(request.viewport.height)，编码 \(request.dimensions.width)×\(request.dimensions.height)，端口 \(port)，\(request.frameRate) fps，\(request.bitRate) bps"
        )
        let offers = videoDecodeCapabilities.value.filter { !hevcDisabled.value || $0.codec != VideoCodec.hevc.rawValue }
        requestedVideoCapabilities.set(offers)
        let message = WireMessage(
                id: requestID,
                kind: .streamStart,
                audioPort: activeAudioPort.map(Int.init),
                audioEnabled: audioRequested.value,
                videoPort: Int(port),
                width: request.dimensions.width,
                height: request.dimensions.height,
                viewportWidth: request.viewport.width,
                viewportHeight: request.viewport.height,
                frameRate: request.frameRate,
                bitRate: request.bitRate,
                receiverUsesWiFi: activeConnection.currentPath?.usesInterfaceType(.wifi),
                displayMode: request.displayMode,
                displayPlacement: request.displayPlacement,
                supportsCursor: true,
                videoCapabilities: offers
            )
        videoReceiver.prepareForConfiguration { [weak self] in
            guard let self else { return }
            self.networkQueue.async { [weak self] in
                guard let self, self.wantsStreaming, self.videoRequestID.value == requestID,
                      self.connection === activeConnection else { return }
                self.send(message, over: activeConnection)
            }
        }
    }

}
