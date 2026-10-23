import GameController
import UIKit

/// 只监听实体按键状态；文字仍交给 UIKit 输入法处理，不重复注入。
@MainActor
final class RemoteKeyboardHardwareMonitor {
    private weak var state: RemoteKeyboardState?
    private var keyboard: GCKeyboard?
    private var observers: [NSObjectProtocol] = []
    var isMonitoring: Bool { keyboard != nil }

    func start(state: RemoteKeyboardState) {
        guard observers.isEmpty else { return }
        self.state = state
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect,
                     UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.attach() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.state?.reset() }
        })
        attach()
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        keyboard?.keyboardInput?.keyChangedHandler = nil
        keyboard = nil
        let previousState = state
        Task { @MainActor [weak previousState] in previousState?.reset() }
        state = nil
    }

    private func attach() {
        keyboard?.keyboardInput?.keyChangedHandler = nil
        state?.reset()
        keyboard = GCKeyboard.coalesced
        keyboard?.keyboardInput?.keyChangedHandler = { [weak self] input, _, code, pressed in
            let shift = input.button(forKeyCode: .leftShift)?.isPressed == true
                || input.button(forKeyCode: .rightShift)?.isPressed == true
            Task { @MainActor in
                guard let self, let state = self.state else { return }
                var modifiers: UIKeyModifierFlags = shift ? [.shift] : []
                if state.capsLock { modifiers.insert(.alphaShift) }
                if pressed { state.press(code.rawValue, modifiers: modifiers) }
                else { state.release(code.rawValue, modifiers: modifiers) }
            }
        }
    }
}
