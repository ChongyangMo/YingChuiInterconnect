import SwiftUI
import UIKit
import YingchuiProtocol

struct RemoteTypingInput: UIViewRepresentable {
    @ObservedObject var state: RemoteKeyboardState
    var systemKeyboard = false
    let onText: (String) -> Void
    let onKey: (RemoteKey, [RemoteKeyModifier]) -> Void

    func makeUIView(context: Context) -> RemoteTypingTextField {
        let field = RemoteTypingTextField()
        configure(field)
        return field
    }

    func updateUIView(_ field: RemoteTypingTextField, context: Context) { configure(field) }

    static func dismantleUIView(_ field: RemoteTypingTextField, coordinator: Void) {
        _ = field.resignFirstResponder()
    }

    private func configure(_ field: RemoteTypingTextField) {
        field.keyboardState = state
        field.onText = onText
        field.onKey = onKey
        if field.isSecureTextEntry != state.secure { field.isSecureTextEntry = state.secure }
        let inputView = systemKeyboard ? nil : field.suppressedKeyboard
        if field.inputView !== inputView { field.inputView = inputView }
        field.placeholder = state.secure ? "密码" : "中文输入"
    }
}

/// 系统输入法仅在组词完成后输出 Unicode；实体按键事件只负责反馈，避免双发。
final class RemoteTypingTextField: UITextField, UITextFieldDelegate {
    var onText: ((String) -> Void)?
    var onKey: ((RemoteKey, [RemoteKeyModifier]) -> Void)?
    weak var keyboardState: RemoteKeyboardState?
    let suppressedKeyboard = UIView(frame: .zero)
    private var committing = false
    private let hardwareMonitor = RemoteKeyboardHardwareMonitor()

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        returnKeyType = .default
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        addTarget(self, action: #selector(commitText), for: .editingChanged)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不支持从编码器创建远程输入框") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { hardwareMonitor.stop(); return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            _ = self.becomeFirstResponder()
        }
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let keyboardState { hardwareMonitor.start(state: keyboardState) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        hardwareMonitor.stop()
        let state = keyboardState
        Task { @MainActor [weak state] in state?.reset() }
        return super.resignFirstResponder()
    }

    override func insertText(_ text: String) {
        super.insertText(text)
        commitText()
    }

    override func unmarkText() {
        super.unmarkText()
        commitText()
    }

    @objc func commitText() {
        guard !committing, markedTextRange == nil, let value = text, !value.isEmpty else { return }
        committing = true
        text = ""
        onText?(value)
        committing = false
    }

    override func deleteBackward() {
        if markedTextRange == nil && (text ?? "").isEmpty { onKey?(.deleteBackward, []) }
        else { super.deleteBackward() }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard markedTextRange == nil else { return true }
        commitText()
        onKey?(.returnKey, [])
        return false
    }

    override var keyCommands: [UIKeyCommand]? {
        markedTextRange == nil ? remoteKeyCommands : super.keyCommands
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if let key = press.key {
                keyboardState?.synchronizeModifiers(key.modifierFlags)
                if !hardwareMonitor.isMonitoring { keyboardState?.press(key.keyCode.rawValue, modifiers: key.modifierFlags) }
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        release(presses)
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        release(presses)
        super.pressesCancelled(presses, with: event)
    }

    private func release(_ presses: Set<UIPress>) {
        for press in presses {
            if !hardwareMonitor.isMonitoring, let key = press.key { keyboardState?.release(key.keyCode.rawValue, modifiers: key.modifierFlags) }
        }
    }
}
