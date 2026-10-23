import AppKit
import CoreGraphics
import Foundation
import Network
import Security
import YingchuiProtocol

extension MacHostModel {
    func handleStreamStart(_ message: WireMessage, from session: HostPeerSession, preservingDisplayMode: Bool = false) {
        let startup = StreamStartupTrace(requestID: message.id, log: eventLog)
        startup.mark("Mac 收到请求")
        eventLog.record(
            "收到视频请求：设备 \(session.deviceID)，编码 \(message.width ?? 0)×\(message.height ?? 0)，视口 \(message.viewportWidth ?? 0)×\(message.viewportHeight ?? 0)，端口 \(message.videoPort ?? 0)"
        )
        guard session.isAuthorized else {
            eventLog.record("拒绝视频请求：设备尚未完成配对授权")
            session.send(WireMessage(id: message.id, kind: .error, detail: "pairing_required"))
            return
        }
        guard claimController(session) else {
            session.send(WireMessage(id: message.id, kind: .error, detail: "controller_busy"))
            return
        }
        guard screenStreamer.isScreenCaptureGranted else {
            eventLog.record("拒绝视频请求：Mac 尚未获得屏幕录制权限")
            session.send(WireMessage(id: message.id, kind: .error, detail: "screen_capture_permission_required"))
            Task { @MainActor [weak self] in
                self?.isScreenCaptureGranted = false
                self?.streamStatusText = "需要屏幕录制权限才能回传画面"
            }
            return
        }
        guard let portValue = message.videoPort,
              (1...65_535).contains(portValue),
              let port = NWEndpoint.Port(rawValue: UInt16(portValue)),
              let host = session.remoteHost else {
            eventLog.record("拒绝视频请求：UDP 视频端点无效")
            session.send(WireMessage(id: message.id, kind: .error, detail: "invalid_video_endpoint"))
            return
        }

        guard let width = message.width, let height = message.height,
              let viewportWidth = message.viewportWidth, let viewportHeight = message.viewportHeight,
              let frameRate = message.frameRate, let bitRate = message.bitRate,
              (2...VideoOutputSizingPolicy.maximumSide).contains(width),
              (2...VideoOutputSizingPolicy.maximumSide).contains(height),
              (2...VideoOutputSizingPolicy.maximumSide).contains(viewportWidth),
              (2...VideoOutputSizingPolicy.maximumSide).contains(viewportHeight),
              (15...120).contains(frameRate), (1_000_000...60_000_000).contains(bitRate) else {
            session.send(WireMessage(id: message.id, kind: .error, detail: "invalid_stream_request"))
            publishStreamStatus("视频请求字段缺失或超出支持范围", isStreaming: false)
            return
        }
        guard let audioEnabled = message.audioEnabled else {
            session.send(WireMessage(id: message.id, kind: .error, detail: "invalid_stream_request"))
            return
        }
        let audioPort: NWEndpoint.Port?
        if audioEnabled {
            guard let port = message.audioPort, (1...65_535).contains(port),
                  let value = NWEndpoint.Port(rawValue: UInt16(port)) else {
                session.send(WireMessage(id: message.id, kind: .error, detail: "invalid_stream_request"))
                return
            }
            audioPort = value
        } else { audioPort = nil }
        guard let displayMode = message.displayMode, displayMode != .standalone,
              let placement = message.displayPlacement else {
            session.send(WireMessage(id: message.id, kind: .error, detail: "invalid_stream_request"))
            return
        }
        let operatingPoint: VideoOperatingPoint
        let fallbackFrameRate: Int?
        do {
            let requested = StreamDimensions(width: width, height: height)
            var capabilities = message.videoCapabilities
            var requestedBitRate = bitRate
#if DEBUG
            if let benchmark = try MacVideoBenchmarkSettings.load() {
                capabilities = (capabilities ?? [VideoDecodeCapability(codec: .h264)])
                    .filter { $0.codec == benchmark.codec.rawValue }
                requestedBitRate = benchmark.bitRate
                eventLog.record("性能对比配置：批次 \(benchmark.runID)，编码 \(benchmark.codec.title)，在途上限 \(benchmark.maximumPendingEncodes)，固定码率 \(benchmark.bitRate)")
            }
#endif
            let offersHEVC = capabilities?.contains { $0.codec == VideoCodec.hevc.rawValue } == true
            operatingPoint = try VideoStreamNegotiation.select(dimensions: requested, frameRate: frameRate,
                bitRate: requestedBitRate, capabilities: capabilities,
                hardwareHEVC: offersHEVC && MacVideoCodecSupport.canEncodeHEVC(requested))
            fallbackFrameRate = try? VideoStreamNegotiation.select(dimensions: requested, frameRate: frameRate,
                bitRate: requestedBitRate, capabilities: capabilities, hardwareHEVC: false).frameRate
            eventLog.record("视频协商结果：\(operatingPoint.codec.title)，\(operatingPoint.dimensions.width)×\(operatingPoint.dimensions.height)，\(operatingPoint.frameRate) 帧/秒")
        } catch {
            session.send(WireMessage(id: message.id, kind: .error, detail: "video_negotiation_failed", errorMessage: error.localizedDescription))
            publishStreamStatus(error.localizedDescription, isStreaming: false)
            return
        }
        stopStreaming(preservingVirtualDisplay: true)
        let virtualSession: MacVirtualDisplaySession
        do {
            try virtualDisplayManager.reconcileDisplays()
            let physical = try virtualDisplayManager.physicalDisplays()
            let selected = virtualDisplayManager.activePhysicalDisplayID ?? selectedDisplayForStreaming.value
            let physicalDisplayID: CGDirectDisplayID?
            if displayMode == .extended || physical.isEmpty ||
                (preservingDisplayMode && virtualDisplayManager.activePhysicalDisplayID == nil) {
                physicalDisplayID = nil
            } else {
                guard let target = selected ?? physical.first, physical.contains(target) else {
                    throw MacDisplayLayout.LayoutError.inconsistentState
                }
                physicalDisplayID = target
            }
            try streamPowerActivity.begin()
            virtualSession = try virtualDisplayManager.activate(
                requestedPixels: StreamDimensions(width: viewportWidth, height: viewportHeight),
                mirroring: physicalDisplayID,
                refreshRate: Double(operatingPoint.frameRate)
            )
            try virtualDisplayManager.arrange(placement: placement)
            try streamPowerActivity.wakeDisplayForStream()
            startup.mark("已请求显示唤醒")
            startup.mark("虚拟显示器配置完成")
            streamDisplayPlacement = placement
        } catch {
            releaseStreamPowerActivity()
            eventLog.record("Retina 虚拟显示器启动失败：\(error.localizedDescription)")
            session.send(
                WireMessage(
                    id: message.id,
                    kind: .error,
                    detail: "virtual_display_failed",
                    errorMessage: error.localizedDescription
                )
            )
            publishStreamStatus(
                "iPad Retina 虚拟显示器启动失败：\(error.localizedDescription)",
                isStreaming: false
            )
            return
        }

        streamingSessionID = session.id
        session.streamRequestID = message.id
        session.streamID = nil
        let videoKey = VideoDatagramCrypto.makeKey()
        publishStreamStatus(
            "正在启动 \(virtualSession.pixelDimensions.width)×\(virtualSession.pixelDimensions.height) Retina 回传",
            isStreaming: true
        )

        session.supportsCursor = message.supportsCursor == true
        session.lastCursorInputSequence = 0
        session.cursorSendInFlight = false
        session.pendingCursorState = nil
        prepareCursor(for: session, requestID: message.id, displayID: virtualSession.displayID) { [weak self, weak session] cursorState in
            guard let self, let session, self.streamingSessionID == session.id,
                  session.streamRequestID == message.id else { return }
            self.launchScreenStream(message, session: session, startup: startup, virtualSession: virtualSession,
                host: host, port: port, audioPort: audioPort, videoKey: videoKey, cursorState: cursorState,
                operatingPoint: operatingPoint, fallbackFrameRate: fallbackFrameRate)
        }
    }

    func stopStreaming(preservingVirtualDisplay: Bool = false) {
        stopCursorUpdates()
        Task { @MainActor [weak self] in self?.activeDisplayState = nil }
        if let streamingSessionID, let session = sessions[streamingSessionID] {
            releaseInputState(for: session)
            session.streamRequestID = nil
        }
        screenStreamer.stop()
        releaseStreamPowerActivity()
        if !preservingVirtualDisplay {
            virtualDisplayManager.deactivate()
        }
        streamingSessionID = nil
        Task { @MainActor [weak self] in
            self?.isStreaming = false
        }
    }
}
