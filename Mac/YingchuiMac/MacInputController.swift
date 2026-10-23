import AppKit
import ApplicationServices
import YingchuiProtocol

final class MacInputController: @unchecked Sendable {
    var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func requestAccessibilityAccess() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    func returnPointer(to display: CGDirectDisplayID) -> Bool {
        guard isAccessibilityGranted, CGDisplayIsActive(display) != 0 else { return false }
        let bounds = CGDisplayBounds(display)
        guard !bounds.isEmpty, let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: bounds.midX, y: bounds.midY), mouseButton: .left) else { return false }
        event.post(tap: .cghidEventTap)
        return true
    }

    @discardableResult
    func movePointer(deltaX: Double, deltaY: Double, buttons: RemoteButtonState = RemoteButtonState()) -> Bool {
        guard isAccessibilityGranted,
              let currentPosition = CGEvent(source: nil)?.location,
              let event = MacPointerEventFactory.movement(from: currentPosition,
                  deltaX: deltaX, deltaY: deltaY, buttons: buttons) else {
            return false
        }

        event.post(tap: .cghidEventTap)
        return true
    }

    @discardableResult
    func setMouseButton(_ button: CGMouseButton, pressed: Bool, position target: CGPoint? = nil, eventTag: Int64 = 0) -> Bool {
        guard isAccessibilityGranted,
              let position = target ?? CGEvent(source: nil)?.location else {
            return false
        }

        guard let eventType = MacInputMapping.mouseEventType(button: button, pressed: pressed) else {
            return false
        }

        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: eventType,
            mouseCursorPosition: position,
            mouseButton: button
        ) else {
            return false
        }
        event.setIntegerValueField(.eventSourceUserData, value: eventTag)
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.post(tap: .cghidEventTap)
        return true
    }

    @discardableResult
    func releaseMouseButtons(_ buttons: Set<PointerButton>) -> Bool {
        var succeeded = true
        for button in buttons.sorted(by: { $0.rawValue < $1.rawValue }) {
            let cgButton: CGMouseButton = button == .left ? .left : .right
            if !setMouseButton(cgButton, pressed: false) {
                succeeded = false
            }
        }
        return succeeded
    }

    @discardableResult
    func scroll(deltaX: Double, deltaY: Double) -> Bool {
        guard isAccessibilityGranted else { return false }

        let horizontal = MacInputMapping.clampedScrollValue(deltaX)
        let vertical = MacInputMapping.clampedScrollValue(deltaY)
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: vertical,
            wheel2: horizontal,
            wheel3: 0
        ) else {
            return false
        }
        event.post(tap: .cghidEventTap)
        return true
    }

    @discardableResult
    func typeText(_ text: String) -> Bool {
        guard isAccessibilityGranted else { return false }
        let characters = Array(text.prefix(128).utf16)
        guard !characters.isEmpty,
              let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return false
        }

        characters.withUnsafeBufferPointer { buffer in
            guard let address = buffer.baseAddress else { return }
            keyDown.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: address)
            keyUp.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: address)
        }
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    @discardableResult
    func pressKey(_ key: RemoteKey, modifiers: [RemoteKeyModifier]) -> Bool {
        guard isAccessibilityGranted,
              let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: MacInputMapping.keyCode(for: key),
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: MacInputMapping.keyCode(for: key),
                  keyDown: false
              ) else {
            return false
        }

        let flags = modifiers.reduce(into: CGEventFlags()) { flags, modifier in
            switch modifier {
            case .command:
                flags.insert(.maskCommand)
            case .option:
                flags.insert(.maskAlternate)
            case .control:
                flags.insert(.maskControl)
            case .shift:
                flags.insert(.maskShift)
            }
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

}
