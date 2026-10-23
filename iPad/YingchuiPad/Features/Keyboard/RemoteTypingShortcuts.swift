import UIKit
import YingchuiProtocol

extension RemoteTypingTextField {
    var remoteKeyCommands: [UIKeyCommand] {
        let navigation = [UIKeyCommand.inputEscape, "\t", UIKeyCommand.inputUpArrow,
                          UIKeyCommand.inputDownArrow, UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow]
        return navigation.map { command($0) }
            + ["a", "c", "v", "w", "x", "z"].map { command($0, modifiers: .command) }
            + [command("z", modifiers: [.command, .shift])]
    }

    private func command(_ input: String, modifiers: UIKeyModifierFlags = []) -> UIKeyCommand {
        let command = UIKeyCommand(input: input, modifierFlags: modifiers, action: #selector(handleRemoteShortcut(_:)))
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    @objc private func handleRemoteShortcut(_ command: UIKeyCommand) {
        let mapping: [String: RemoteKey] = [UIKeyCommand.inputEscape:.escape, "\t":.tab,
            UIKeyCommand.inputUpArrow:.arrowUp, UIKeyCommand.inputDownArrow:.arrowDown,
            UIKeyCommand.inputLeftArrow:.arrowLeft, UIKeyCommand.inputRightArrow:.arrowRight,
            "a":.letterA, "c":.letterC, "v":.letterV, "w":.letterW, "x":.letterX, "z":.letterZ]
        guard let input = command.input, let key = mapping[input] else { return }
        var modifiers: [RemoteKeyModifier] = []
        if command.modifierFlags.contains(.command) { modifiers.append(.command) }
        if command.modifierFlags.contains(.shift) { modifiers.append(.shift) }
        commitText()
        onKey?(key, modifiers)
    }
}
