import AppKit
import ApplicationServices
import YingchuiProtocol

extension MacHostModel {
    func handleTouch(_ touch: RemoteTouchInput, message: WireMessage, from session: HostPeerSession) {
        guard streamingSessionID == session.id, let streamID = session.streamID, message.streamID == streamID,
              let display = virtualDisplayManager.activeDisplayID, CGDisplayIsActive(display) != 0 else {
            rejectInvalidControlMessage(session, messageID: message.id, reason: "触摸目标画面已变化，请等待新画面")
            return
        }
        do {
            if let input = message.cursorInput {
                guard session.supportsCursor, input.isValid, input.sequence > session.lastCursorInputSequence else {
                    throw CursorError.unavailable("触摸光标序号无效")
                }
            }
            try validateTouchTransition(touch, activeGesture: session.touchGestureID)
            let bounds = CGDisplayBounds(display)
            let point = try MacTouchEventFactory.position(for: touch, bounds: bounds)
            let count: Int
            if touch.phase == .tap {
                count = session.touchClickSequence.clickCount(at: point, now: ProcessInfo.processInfo.systemUptime,
                                                              interval: NSEvent.doubleClickInterval)
            } else {
                session.touchClickSequence = MacTouchClickSequence()
                count = 1
            }
            let events = try MacTouchEventFactory.events(for: touch, bounds: bounds, clickCount: count)
            if let phase = touch.scrollPhase {
                if phase.isTerminal { session.touchScrollEndEvent = nil }
                else {
                    let end = RemoteTouchInput(phase: .scroll, x: touch.x, y: touch.y,
                        deltaX: 0, deltaY: 0, scrollPhase: phase.isMomentum ? .momentumEnded : .cancelled)
                    session.touchScrollEndEvent = try MacTouchEventFactory.events(for: end, bounds: bounds).last
                }
            }
            // 先完整生成事件，再按顺序注入，点击不会落在鼠标原来的位置。
            for event in events {
                if let input = message.cursorInput { event.setIntegerValueField(.eventSourceUserData, value: input.eventTag) }
                event.post(tap: .cghidEventTap)
            }
            if let input = message.cursorInput { session.lastCursorInputSequence = input.sequence }
            if touch.phase == .dragBegan {
                session.touchGestureID = touch.gestureID
                session.remoteButtonState.record(.left, pressed: true)
            } else if touch.phase == .dragEnded {
                session.touchGestureID = nil
                session.remoteButtonState.record(.left, pressed: false)
            }
            screenStreamer.recordRemoteInteraction()
            session.send(WireMessage(id: message.id, kind: .controlAck))
        } catch {
            rejectInvalidControlMessage(session, messageID: message.id, reason: error.localizedDescription)
        }
    }

    func validateTouchTransition(_ touch: RemoteTouchInput, activeGesture: UUID?) throws {
        try touch.validate()
        switch touch.phase {
        case .dragMoved, .dragEnded:
            guard touch.gestureID == activeGesture else { throw TouchSequenceError.invalid }
        case .dragBegan, .tap, .rightTap, .scroll, .hover:
            guard activeGesture == nil else { throw TouchSequenceError.invalid }
        }
    }
}

private enum TouchSequenceError: LocalizedError {
    case invalid
    var errorDescription: String? { "触摸手势顺序无效，已拒绝过期或重叠手势" }
}
