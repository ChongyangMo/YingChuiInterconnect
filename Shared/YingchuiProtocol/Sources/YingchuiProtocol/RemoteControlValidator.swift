import Foundation

public enum RemoteControlCommand: Equatable, Sendable {
    case touchInput(RemoteTouchInput)
    case pointerReturn
    case cursorMove(RemoteCursorInput)
    case pointerMove(deltaX: Double, deltaY: Double)
    case mouseButton(PointerButton, pressed: Bool)
    case scroll(deltaX: Double, deltaY: Double)
    case textInput(String)
    case keyPress(RemoteKey, modifiers: [RemoteKeyModifier])
    case keyboardLanguage(RemoteKeyboardLanguage)
}

public enum RemoteControlValidationError: LocalizedError, Equatable {
    case unsupportedKind
    case missingField
    case invalidCoordinate
    case textTooLong
    case emptyText

    public var errorDescription: String? {
        switch self {
        case .unsupportedKind:
            return "消息不是可执行的控制指令"
        case .missingField:
            return "控制消息字段不完整"
        case .invalidCoordinate:
            return "控制消息坐标无效"
        case .textTooLong:
            return "单条文字指令超过 128 字符"
        case .emptyText:
            return "文字输入不能为空"
        }
    }
}

public enum RemoteControlValidator {
    public static func command(from message: WireMessage) throws -> RemoteControlCommand {
        switch message.kind {
        case .touchInput:
            guard let touch = message.touch, message.streamID != nil else {
                throw RemoteControlValidationError.missingField
            }
            try touch.validate()
            return .touchInput(touch)
        case .pointerReturn:
            return .pointerReturn
        case .pointerMove:
            if let input = message.cursorInput {
                guard message.streamID != nil, input.isValid else { throw RemoteControlValidationError.invalidCoordinate }
                return .cursorMove(input)
            }
            let values = try coordinates(from: message, limit: 500)
            return .pointerMove(deltaX: values.x, deltaY: values.y)
        case .mouseButton:
            guard let button = message.button, let pressed = message.pressed else {
                throw RemoteControlValidationError.missingField
            }
            return .mouseButton(button, pressed: pressed)
        case .scroll:
            let values = try coordinates(from: message, limit: 300)
            return .scroll(deltaX: values.x, deltaY: values.y)
        case .textInput:
            guard let text = message.text else {
                throw RemoteControlValidationError.missingField
            }
            guard text.count <= 128 else { throw RemoteControlValidationError.textTooLong }
            let value = text
            guard !value.isEmpty else { throw RemoteControlValidationError.emptyText }
            return .textInput(value)
        case .keyboardLanguage:
            guard let language = message.keyboardLanguage else { throw RemoteControlValidationError.missingField }
            return .keyboardLanguage(language)
        case .keyPress:
            guard let key = message.key else {
                throw RemoteControlValidationError.missingField
            }
            return .keyPress(key, modifiers: message.modifiers ?? [])
        default:
            throw RemoteControlValidationError.unsupportedKind
        }
    }

    private static func coordinates(
        from message: WireMessage,
        limit: Double
    ) throws -> (x: Double, y: Double) {
        guard let deltaX = message.deltaX, let deltaY = message.deltaY else {
            throw RemoteControlValidationError.missingField
        }
        guard deltaX.isFinite, deltaY.isFinite else {
            throw RemoteControlValidationError.invalidCoordinate
        }
        return (
            max(-limit, min(limit, deltaX)),
            max(-limit, min(limit, deltaY))
        )
    }
}
