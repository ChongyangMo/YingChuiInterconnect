import ApplicationServices
import YingchuiProtocol

enum MacPointerEventFactory {
    static func movement(from position: CGPoint, deltaX: Double, deltaY: Double,
                         buttons: RemoteButtonState) -> CGEvent? {
        guard position.x.isFinite, position.y.isFinite, deltaX.isFinite, deltaY.isFinite else { return nil }
        let type: CGEventType
        let button: CGMouseButton
        if buttons.isPressed(.left) {
            type = .leftMouseDragged
            button = .left
        } else if buttons.isPressed(.right) {
            type = .rightMouseDragged
            button = .right
        } else {
            type = .mouseMoved
            button = .left
        }
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
            mouseCursorPosition: CGPoint(x: position.x + deltaX, y: position.y + deltaY),
            mouseButton: button) else { return nil }
        event.setDoubleValueField(.mouseEventDeltaX, value: deltaX)
        event.setDoubleValueField(.mouseEventDeltaY, value: deltaY)
        event.setIntegerValueField(.mouseEventClickState, value: type == .mouseMoved ? 0 : 1)
        return event
    }
}
