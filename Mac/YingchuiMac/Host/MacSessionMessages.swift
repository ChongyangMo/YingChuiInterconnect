import AppKit
import CoreGraphics
import Foundation
import Network
import Security
import YingchuiProtocol

extension MacHostModel {
    func handle(_ message: WireMessage, from session: HostPeerSession) {
        guard !session.isSuperseded else { return }
        guard let wireVersion = WireProtocolCompatibility.negotiatedVersion(peerVersion: message.version,
            peerMinimum: message.minimumProtocolVersion ?? session.peerMinimumProtocolVersion) else {
            session.send(WireMessage(kind: .error, detail: "unsupported_protocol_version")) {
                session.cancel()
            }
            return
        }

        session.wireVersion = wireVersion
        if message.kind == .hello { session.peerMinimumProtocolVersion = message.minimumProtocolVersion }

        switch message.kind {
        case .accountLink:
            handleAccountLink(message, from: session)
        case .hello:
            handleHello(message, from: session)
        case .pairRequest:
            handlePairRequest(message, from: session)
        case .ping:
            session.send(WireMessage(id: message.id, kind: .pong))
        case .touchInput, .pointerReturn, .pointerMove, .mouseButton, .scroll, .textInput, .keyPress, .keyboardLanguage:
            handleControl(message, from: session)
        case .clipboardGet, .clipboardSet:
            handleClipboard(message, from: session)
        case .clipboardResult:
            break
        case .controlAck:
            break
        case .streamStart:
            handleStreamStart(message, from: session)
        case .streamStop:
            if streamingSessionID == session.id {
                stopStreaming(preservingVirtualDisplay: true)
                virtualDisplayManager.deactivate(after: 5)
                publishStreamStatus("客户端已停止屏幕回传", isStreaming: false)
            }
        case .keyframeRequest:
            if streamingSessionID == session.id, session.isAuthorized,
               let streamID = session.streamID, message.streamID == streamID {
                if let repair = message.videoRepair {
                    guard repair.isValid else {
                        session.send(WireMessage(id: message.id, kind: .error, detail: "invalid_video_repair"))
                        return
                    }
                    screenStreamer.repairVideo(repair, streamID: streamID)
                } else {
                    screenStreamer.requestKeyFrame(reportProgress: true)
                }
            }
        case .streamStats:
            guard streamingSessionID == session.id, session.isAuthorized else { return }
            // 已停止的旧流统计不能污染当前流，明确拒绝但不切换当前会话。
            guard let streamID = session.streamID, message.streamID == streamID,
                  let decoded = message.framesDecoded, let dropped = message.framesDropped else {
                session.send(WireMessage(kind: .error, detail: "invalid_stream_statistics"))
                return
            }
            do {
                if let lossRate = try session.statistics.lossRate(decoded: decoded, dropped: dropped, networkMissing: message.networkFramesMissing) {
                    screenStreamer.adaptBitRate(lossRate: lossRate)
                }
                Task { @MainActor [weak self] in self?.clientDecodedFrameCount = decoded }
            } catch {
                session.send(WireMessage(kind: .error, detail: "invalid_stream_statistics"))
                publishStatus(error.localizedDescription)
            }
        case .heartbeat:
            session.send(WireMessage(id: message.id, kind: .heartbeat))
        case .pairResult, .pong, .videoConfig, .displayState, .cursorState, .error:
            break
        }
    }

    func handleControl(_ message: WireMessage, from session: HostPeerSession) {
        guard session.isAuthorized else {
            session.send(WireMessage(id: message.id, kind: .error, detail: "pairing_required"))
            return
        }
        guard claimController(session) else {
            session.send(WireMessage(id: message.id, kind: .error, detail: "controller_busy"))
            return
        }
        guard inputController.isAccessibilityGranted else {
            session.send(WireMessage(
                id: message.id,
                kind: .error,
                detail: "accessibility_permission_required"
            ))
            Task { @MainActor [weak self] in
                self?.isAccessibilityGranted = false
                self?.statusText = "需要辅助功能权限才能执行控制"
            }
            return
        }

        let command: RemoteControlCommand
        do {
            command = try RemoteControlValidator.command(from: message)
        } catch {
            rejectInvalidControlMessage(
                session,
                messageID: message.id,
                reason: error.localizedDescription
            )
            return
        }

        let succeeded: Bool
        switch command {
        case .touchInput(let touch):
            handleTouch(touch, message: message, from: session)
            return
        case .pointerReturn:
            guard streamingSessionID == session.id, let current = session.streamID,
                  message.streamID == current, let display = virtualDisplayManager.activeDisplayID else {
                rejectInvalidControlMessage(session, messageID: message.id, reason: "回传屏幕已变化")
                return
            }
            succeeded = inputController.returnPointer(to: display)
        case .cursorMove(let input):
            handleCursorInput(input, message: message, session: session)
            return
        case .pointerMove(let deltaX, let deltaY):
            succeeded = inputController.movePointer(deltaX: deltaX, deltaY: deltaY,
                buttons: session.remoteButtonState)
        case .mouseButton(let button, let pressed):
            let cgButton: CGMouseButton = button == .left ? .left : .right
            if let input = message.cursorInput {
                guard session.supportsCursor, input.isValid, message.streamID == session.streamID,
                      streamingSessionID == session.id, input.sequence > session.lastCursorInputSequence else {
                    rejectInvalidControlMessage(session, messageID: message.id, reason: "鼠标按键定位信息无效")
                    return
                }
                succeeded = inputController.setMouseButton(cgButton, pressed: pressed,
                    position: CGPoint(x: input.position.x, y: input.position.y), eventTag: input.eventTag)
                if succeeded { session.lastCursorInputSequence = input.sequence }
            } else {
                succeeded = inputController.setMouseButton(cgButton, pressed: pressed)
            }
            if succeeded {
                session.remoteButtonState.record(button, pressed: pressed)
            }
        case .scroll(let deltaX, let deltaY):
            succeeded = inputController.scroll(deltaX: deltaX, deltaY: deltaY)
        case .textInput(let text):
            succeeded = inputController.typeText(text)
        case .keyPress(let key, let modifiers):
            succeeded = inputController.pressKey(key, modifiers: modifiers)
        case .keyboardLanguage(let language):
            do {
                try MacKeyboardInputSource.select(language)
                eventLog.record("Mac 输入法已切换：\(language == .pinyin ? "简体拼音" : "ABC")")
                session.send(WireMessage(id: message.id, kind: .controlAck, keyboardLanguage: language))
                return
            } catch {
                session.send(WireMessage(id: message.id, kind: .error, detail: "keyboard_language_failed", errorMessage: error.localizedDescription))
                publishStatus(error.localizedDescription)
                return
            }
        }
        guard succeeded else {
            session.send(WireMessage(id: message.id, kind: .error, detail: "input_injection_failed"))
            publishStatus("Mac 输入注入失败，请刷新辅助功能权限后重试")
            return
        }
        screenStreamer.recordRemoteInteraction()
        session.send(WireMessage(id: message.id, kind: .controlAck))
    }

    func rejectInvalidControlMessage(
        _ session: HostPeerSession,
        messageID: UUID,
        reason: String
    ) {
        session.send(WireMessage(id: messageID, kind: .error, detail: "invalid_control_message"))
        publishStatus("控制消息无效：\(reason)")
    }

    func remove(_ session: HostPeerSession) {
        detachAccountLink(session)
        releaseInputState(for: session)
        if streamingSessionID == session.id {
            stopStreaming(preservingVirtualDisplay: true)
            virtualDisplayManager.deactivate(after: 5)
            publishStreamStatus("视频客户端已断开", isStreaming: false)
        }
        if controlSessionID == session.id { controlSessionID = nil }
        sessions.removeValue(forKey: session.id)
        publishTrustedDevices()
        publishSessionCount()
    }

    func releaseInputState(for session: HostPeerSession) {
        session.touchScrollEndEvent?.post(tap: .cghidEventTap)
        session.touchScrollEndEvent = nil
        session.touchGestureID = nil
        session.touchClickSequence = MacTouchClickSequence()
        let pressedButtons = session.remoteButtonState.takePressedButtons()
        guard !pressedButtons.isEmpty else { return }
        if !inputController.releaseMouseButtons(pressedButtons) {
            publishStatus("客户端断开后释放鼠标按键失败，请在 Mac 上点击一次鼠标")
        }
    }
}
