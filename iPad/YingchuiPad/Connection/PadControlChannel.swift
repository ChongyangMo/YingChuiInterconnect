import CryptoKit
import Foundation
import Network
import Security
import UIKit
import YingchuiProtocol

extension PadConnectionModel {
    @MainActor
    func sendPing() {
        networkQueue.async { [weak self] in
            self?.sendPingOnNetworkQueue()
        }
    }

    func startPingTimer() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: networkQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.sendPingOnNetworkQueue()
        }
        pingTimer = timer
        timer.resume()
    }

    func sendPingOnNetworkQueue() {
        guard let connection else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        reportExpiredControlAcknowledgements(at: now)
        if pendingPings.values.contains(where: { now > $0.uptimeNanoseconds && now - $0.uptimeNanoseconds > 5_000_000_000 }) {
            publishStatus("心跳超时，正在重新连接")
            connection.cancel()
            return
        }
        let message = WireMessage(kind: .ping)
        pendingPings[message.id] = PendingPing(
            uptimeNanoseconds: now,
            wallClockMilliseconds: message.sentAtMilliseconds
        )
        send(message, over: connection)

        if pendingPings.count > 30 {
            pendingPings.removeAll(keepingCapacity: true)
        }
    }

    func send(_ message: WireMessage, over activeConnection: NWConnection) {
        do {
            var outgoing = message
            outgoing.version = wireVersion
            activeConnection.send(content: try WireCodec.encode(outgoing), completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.publishStatus("发送失败：\(error.localizedDescription)")
                }
            })
        } catch {
            publishStatus("编码失败：\(error.localizedDescription)")
        }
    }

    func receiveNext(on activeConnection: NWConnection) {
        let epoch = connectionEpoch.value
        activeConnection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak activeConnection] data, _, isComplete, error in
            guard let self, let activeConnection, self.connection === activeConnection, self.connectionEpoch.value == epoch else { return }

            if let data, !data.isEmpty {
                do {
                    for message in try self.decoder.append(data) {
                        guard self.connection === activeConnection, self.connectionEpoch.value == epoch else { return }
                        self.handle(message)
                    }
                } catch {
                    self.handleConnectionClosed(activeConnection, reason: "协议错误：\(error.localizedDescription)")
                    return
                }
            }

            if let error {
                self.handleConnectionClosed(activeConnection, reason: "接收失败：\(error.localizedDescription)")
                return
            }
            if isComplete {
                self.handleConnectionClosed(activeConnection, reason: "Mac 已关闭连接")
                return
            }
            self.receiveNext(on: activeConnection)
        }
    }

    func handle(_ message: WireMessage) {
        guard let negotiated = WireProtocolCompatibility.negotiatedVersion(peerVersion: message.version,
            peerMinimum: message.minimumProtocolVersion ?? peerMinimumProtocolVersion) else {
            desiredEndpoint = nil
            if let connection {
                handleConnectionClosed(connection, reason: "协议版本不兼容")
            } else {
                publishStatus("协议版本不兼容")
            }
            return
        }

        wireVersion = negotiated
        if message.kind == .hello { peerMinimumProtocolVersion = message.minimumProtocolVersion }

        switch message.kind {
        case .accountLink:
            handleAccountLink(message)
        case .hello:
            handleHello(message)
        case .pairResult:
            handlePairResult(message)
        case .pong:
            handlePong(message)
        case .clipboardResult:
            handleClipboardResult(message)
        case .clipboardGet, .clipboardSet:
            break
        case .controlAck:
            handleControlAcknowledgement(message)
        case .error:
            if pendingKeyboardLanguageRequest == message.id { finishKeyboardLanguageChange(error: message.errorMessage ?? "Mac 输入法切换失败") }
            if pendingTextIDs.contains(message.id) {
                pendingTextIDs.removeAll()
                publishTransferStatus("部分文字可能未输入，请检查连接与权限")
            }
            controlAcknowledgements.cancel(id: message.id)
            handleError(message.detail, errorMessage: message.errorMessage, requestID: message.id)
        case .displayState:
            handleDisplayState(message)
        case .cursorState:
            handleCursorState(message)
        case .videoConfig:
            handleVideoConfiguration(message)
        case .heartbeat:
            break
        case .pairRequest, .ping, .touchInput, .pointerReturn, .pointerMove, .mouseButton, .scroll, .textInput, .keyPress, .keyboardLanguage,
             .streamStart, .streamStop, .keyframeRequest, .streamStats:
            break
        }
    }

    func handlePong(_ message: WireMessage) {
        guard let pending = pendingPings.removeValue(forKey: message.id) else { return }
        let receivedAtUptime = DispatchTime.now().uptimeNanoseconds
        let receivedAtWallClock = UInt64(Date().timeIntervalSince1970 * 1_000)
        let elapsed = receivedAtUptime - pending.uptimeNanoseconds
        let milliseconds = Double(elapsed) / 1_000_000
        if let generation = videoReceiverGeneration.value {
            videoReceiver.recordRoundTrip(milliseconds: milliseconds, generation: generation)
        }
        peerClockEstimator.record(sentWallMilliseconds: pending.wallClockMilliseconds,
            receivedWallMilliseconds: receivedAtWallClock, peerWallMilliseconds: message.sentAtMilliseconds,
            roundTripMilliseconds: milliseconds, receivedAtUptime: receivedAtUptime)
        peerClockEstimateState.set(peerClockEstimator.estimate)
        clockOffsetMilliseconds = peerClockEstimator.estimate?.offsetMilliseconds
        if let estimate = peerClockEstimator.estimate {
            eventLog.recordPeriodic("时钟校准：偏移 \(String(format: "%.2f", estimate.offsetMilliseconds)) 毫秒，最低往返 \(String(format: "%.2f", estimate.minimumRoundTripMilliseconds)) 毫秒，窗口 \(estimate.sampleCount) 个真实样本",
                key: "时钟校准", intervalNanoseconds: 10_000_000_000)
        }
        let epoch = connectionEpoch.value
        Task { @MainActor [weak self] in
            guard let self, self.connectionEpoch.value == epoch else { return }
            self.streamMetrics.recordRoundTrip(milliseconds, now: receivedAtUptime)
            self.roundTripMilliseconds = milliseconds
            self.roundTripSamples.append(milliseconds)
            self.roundTripP95Milliseconds = self.roundTripSamples.percentile(0.95)
            if let latestControlRoundTrip = self.latestControlRoundTripState.mutate({ value in
                let result = value
                value = nil
                return result
            }) {
                self.controlRoundTripMilliseconds = latestControlRoundTrip
                self.controlRoundTripSamples.append(latestControlRoundTrip)
            }
            self.controlRoundTripP95Milliseconds = self.controlRoundTripSamples.percentile(0.95)
        }
    }

    func handleControlAcknowledgement(_ message: WireMessage) {
        let receivedAt = DispatchTime.now().uptimeNanoseconds
        guard let measurement = controlAcknowledgements.acknowledgeMeasurement(
            id: message.id,
            at: receivedAt
        ) else { return }
        if pendingTextIDs.remove(message.id) != nil, pendingTextIDs.isEmpty { publishTransferStatus("文字已输入 Mac") }
        if pendingKeyboardLanguageRequest == message.id {
            finishKeyboardLanguageChange(language: message.keyboardLanguage)
        }
        let milliseconds = measurement.roundTripMilliseconds
        controlPipelineMetrics.acknowledgement.record(from: measurement.sentAtUptimeNanoseconds, to: receivedAt)
        controlPipelineMetrics.reportIfNeeded(to: eventLog, now: receivedAt)
        if wantsStreaming {
            guard message.sentAtMilliseconds <= UInt64.max / 1_000 else {
                publishStatus("Mac 控制回执时间戳无效")
                return
            }
            pendingVisualControlState.set(
                PendingVisualControl(
                    sentAtUptimeNanoseconds: measurement.sentAtUptimeNanoseconds,
                    executedAtMacMicroseconds: message.sentAtMilliseconds * 1_000
                )
            )
        }
        if didReportControlAcknowledgementTimeout {
            didReportControlAcknowledgementTimeout = false
            publishStatus("控制通道已恢复")
        }
        latestControlRoundTripState.set(milliseconds)
    }

    func reportExpiredControlAcknowledgements(at uptimeNanoseconds: UInt64) {
        guard controlAcknowledgements.expire(at: uptimeNanoseconds) > 0,
              !didReportControlAcknowledgementTimeout else { return }
        didReportControlAcknowledgementTimeout = true
        if !pendingTextIDs.isEmpty { pendingTextIDs.removeAll(); publishTransferStatus("文字输入回执超时，请检查 Mac") }
        publishStatus("控制执行回执超时，请检查连接")
    }

    func handleError(_ detail: String?, errorMessage: String?, requestID: UUID? = nil) {
        let streamErrors: Set<String> = ["screen_capture_permission_required", "invalid_stream_request",
            "invalid_video_endpoint", "display_unavailable", "virtual_display_failed", "stream_runtime_failed", "video_codec_failed", "video_negotiation_failed"]
        if let detail, streamErrors.contains(detail), let requestID, videoRequestID.value != requestID {
            eventLog.record("已拒绝过期视频请求的错误响应")
            return
        }
        let diagnosticText = errorMessage.map { "，原因：\($0)" } ?? ""
        eventLog.record("Mac 返回错误：\(detail ?? "未提供错误码")\(diagnosticText)")
        let status: String
        switch detail {
        case "keyboard_language_failed":
            status = errorMessage ?? "Mac 输入法切换失败"
        case "unsupported_protocol_version":
            status = "Mac 与 iPad 版本不兼容，请同时更新两端"
        case "pairing_required":
            failTrust("Mac 要求重新配对，已断开连接")
            return
        case "accessibility_permission_required":
            status = "Mac 尚未授权辅助功能权限"
        case "screen_capture_permission_required":
            finishStreamingFailure("Mac 尚未授权屏幕录制权限")
            return
        case "invalid_stream_statistics":
            status = "Mac 拒绝了无效或过期的视频统计"
        case "invalid_stream_request":
            finishStreamingFailure("视频请求字段缺失或超出支持范围")
            return
        case "invalid_video_endpoint":
            finishStreamingFailure("视频接收端口协商失败")
            return
        case "display_unavailable":
            finishStreamingFailure("Mac 没有可用于镜像的物理显示器")
            return
        case "virtual_display_failed":
            finishStreamingFailure(errorMessage.map { "Mac Retina 虚拟显示器启动失败：\($0)" }
                ?? "Mac Retina 虚拟显示器启动失败")
            return
        case "credential_store_failed":
            status = "Mac 无法保存配对凭据，请检查钥匙串后重试"
        case "controller_busy":
            finishStreamingFailure("Mac 正由其他设备控制")
            return
        case "stream_stopped_by_host":
            finishStreamingFailure("Mac 已停止回传并恢复显示器")
            return
        case "input_injection_failed":
            status = "Mac 输入注入失败，请刷新辅助功能权限后重试"
        case "invalid_control_message":
            status = "控制消息字段不完整，请重新连接"
        case "video_negotiation_failed":
            finishStreamingFailure(errorMessage ?? "双方没有可用的视频格式，请降低画质后重试")
            return
        case "video_codec_failed":
            disableHEVC(reason: errorMessage ?? "Mac 编码器无法持续输出", beforeConfiguration: true)
            scheduleStreamRecoveryAfterFailure(reason: errorMessage ?? "视频编码器失败")
            return
        case "stream_runtime_failed":
            scheduleStreamRecoveryAfterFailure(reason: errorMessage ?? "Mac 报告回传运行失败")
            return
        default:
            status = "Mac 返回了未识别的错误：\(detail ?? "无错误码")"
        }
        publishStatus(status)
    }
}
