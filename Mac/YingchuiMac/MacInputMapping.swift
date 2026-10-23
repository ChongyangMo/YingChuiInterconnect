import ApplicationServices
import YingchuiProtocol

enum MacInputMapping {
    static func mouseEventType(button: CGMouseButton, pressed: Bool) -> CGEventType? {
        switch (button, pressed) {
        case (.left, true):
            return .leftMouseDown
        case (.left, false):
            return .leftMouseUp
        case (.right, true):
            return .rightMouseDown
        case (.right, false):
            return .rightMouseUp
        default:
            return nil
        }
    }

    static func keyCode(for key: RemoteKey) -> CGKeyCode {
        switch key {
        case .escape: 53
        case .returnKey: 36
        case .tab: 48
        case .space: 49
        case .deleteBackward: 51
        case .deleteForward: 117
        case .arrowUp: 126
        case .arrowDown: 125
        case .arrowLeft: 123
        case .arrowRight: 124
        case .home: 115
        case .end: 119
        case .pageUp: 116
        case .pageDown: 121
        case .letterA: 0
        case .letterC: 8
        case .letterV: 9
        case .letterW: 13
        case .letterX: 7
        case .letterZ: 6
        case .letterB: 11
        case .letterD: 2
        case .letterE: 14
        case .letterF: 3
        case .letterG: 5
        case .letterH: 4
        case .letterI: 34
        case .letterJ: 38
        case .letterK: 40
        case .letterL: 37
        case .letterM: 46
        case .letterN: 45
        case .letterO: 31
        case .letterP: 35
        case .letterQ: 12
        case .letterR: 15
        case .letterS: 1
        case .letterT: 17
        case .letterU: 32
        case .letterY: 16
        case .digit0: 29
        case .digit1: 18
        case .digit2: 19
        case .digit3: 20
        case .digit4: 21
        case .digit5: 23
        case .digit6: 22
        case .digit7: 26
        case .digit8: 28
        case .digit9: 25
        case .minus: 27
        case .equal: 24
        case .leftBracket: 33
        case .rightBracket: 30
        case .backslash: 42
        case .semicolon: 41
        case .quote: 39
        case .grave: 50
        case .comma: 43
        case .period: 47
        case .slash: 44
        }
    }

    static func clampedScrollValue(_ value: Double) -> Int32 {
        guard value.isFinite else { return 0 }
        return Int32(max(Double(Int32.min), min(Double(Int32.max), value.rounded())))
    }
}
