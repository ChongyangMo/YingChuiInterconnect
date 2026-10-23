import AppKit
import Network
import YingchuiProtocol

extension MacHostModel {
    func launchScreenStream(_ message: WireMessage, session: HostPeerSession,
                            startup: StreamStartupTrace, virtualSession: MacVirtualDisplaySession,
                            host: NWEndpoint.Host, port: NWEndpoint.Port, audioPort: NWEndpoint.Port?,
                            videoKey: Data, cursorState: RemoteCursorState?,
                            operatingPoint: VideoOperatingPoint, fallbackFrameRate: Int?) {
        guard let placement = message.displayPlacement else {
            session.send(WireMessage(id: message.id, kind: .error, detail: "invalid_stream_request"))
            stopStreaming()
            return
        }
        // 镜像建立后虚拟屏是活动主屏，物理屏只是非活动的硬件镜像成员；
        // ScreenCaptureKit 只枚举活动主屏，因此必须采集虚拟屏本身。
        screenStreamer.start(
            startupTrace: startup,
            destinationHost: host,
            destinationPort: port,
            audioPort: audioPort,
            requestedWidth: operatingPoint.dimensions.width,
            requestedHeight: operatingPoint.dimensions.height,
            expectedSourceWidth: virtualSession.pixelDimensions.width,
            expectedSourceHeight: virtualSession.pixelDimensions.height,
            frameRate: operatingPoint.frameRate,
            bitRate: operatingPoint.bitRate,
            codec: operatingPoint.codec,
            h264FallbackFrameRate: fallbackFrameRate,
            receiverUsesWiFi: message.receiverUsesWiFi,
            mediaPacketSink: usbHost.mediaSink(remoteEndpoint: session.remoteEndpoint),
            videoKey: videoKey,
            displayID: virtualSession.displayID,
            separatesCursor: cursorState != nil,
            onConfiguration: { [weak self, weak session] configuration in
                self?.networkQueue.async { [weak self, weak session] in
                    guard let self, let session, self.streamingSessionID == session.id, session.streamRequestID == message.id else { return }
                    let displayState: RemoteDisplayState
                    do {
                        try self.virtualDisplayManager.arrange(placement: placement)
                        displayState = try self.virtualDisplayManager.confirmedState(placement: placement)
                    } catch {
                        session.send(WireMessage(id: message.id, kind: .error, detail: "stream_runtime_failed", errorMessage: error.localizedDescription))
                        self.stopStreaming()
                        self.publishStreamStatus(error.localizedDescription, isStreaming: false)
                        return
                    }
                    self.publishDisplayState(displayState)
                    session.streamID = configuration.streamID
                    session.statistics.reset()
                    startup.mark("发送视频配置", detail: "流 \(configuration.streamID)")
                    session.send(
                        WireMessage(
                            id: message.id,
                            kind: .videoConfig,
                            streamID: configuration.streamID,
                            codec: configuration.codec.rawValue,
                            width: configuration.width,
                            height: configuration.height,
                            frameRate: configuration.frameRate,
                            bitRate: configuration.bitRate,
                            parameterSets: configuration.parameterSets.map { $0.base64EncodedString() },
                            displayState: displayState,
                            videoKey: configuration.videoKey.base64EncodedString(),
                            supportsVideoRepair: true,
                            supportsCursor: cursorState != nil,
                            cursorState: cursorState
                        )
                    )
                    self.startCursorUpdates(for: session, requestID: message.id, streamID: configuration.streamID)
#if DEBUG
                    self.scheduleInvestigationDisconnect(session: session, requestID: message.id, streamID: configuration.streamID)
#endif
                }
            },
            onStatus: { [weak self, weak session] status in
                self?.networkQueue.async { [weak self, weak session] in
                    guard let self, let session, self.streamingSessionID == session.id, session.streamRequestID == message.id else { return }
                    self.publishStreamStatus(status, isStreaming: true)
                }
            },
            onStopped: { [weak self, weak session] status, cause in
                guard let self, let session else { return }
                self.networkQueue.async { [weak self, weak session] in
                    guard let self, let session, self.streamingSessionID == session.id, session.streamRequestID == message.id else { return }
                    self.handleCaptureTermination(status: status, cause: cause, message: message, session: session)
                }
            },
            onStatistics: { [weak self, weak session] encoded, dropped in
                self?.networkQueue.async { [weak self, weak session] in
                    guard let self, let session, self.streamingSessionID == session.id, session.streamRequestID == message.id else { return }
                    Task { @MainActor [weak self] in
                        self?.encodedFrameCount = encoded
                        self?.droppedFrameCount = dropped
                    }
                }
            }
        )
    }

}
