import Foundation

public struct RemoteButtonState: Sendable {
    private var pressedButtons: Set<PointerButton> = []

    public init() {}

    public func isPressed(_ button: PointerButton) -> Bool {
        pressedButtons.contains(button)
    }

    public mutating func record(_ button: PointerButton, pressed: Bool) {
        if pressed {
            pressedButtons.insert(button)
        } else {
            pressedButtons.remove(button)
        }
    }

    public mutating func takePressedButtons() -> Set<PointerButton> {
        let buttons = pressedButtons
        pressedButtons.removeAll(keepingCapacity: true)
        return buttons
    }

    public var isEmpty: Bool {
        pressedButtons.isEmpty
    }
}
