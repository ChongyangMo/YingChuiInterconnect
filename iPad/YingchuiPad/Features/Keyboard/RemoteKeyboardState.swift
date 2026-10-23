import Combine
import SwiftUI

/// 按 HID 位置关联实体键与屏幕按键，松开、取消和失焦都释放高亮。
@MainActor
final class RemoteKeyboardState: ObservableObject {
    @Published var secure = false
    @Published private(set) var lastPressedKey: Int?
    @Published private(set) var pressedKeys: Set<Int> = []
    @Published private(set) var shiftHeld = false
    @Published private(set) var capsLock = false
    private var releaseTasks: [Int: Task<Void, Never>] = [:]
    private var pressedAt: [Int: ContinuousClock.Instant] = [:]

    func press(_ code: Int, modifiers: UIKeyModifierFlags) {
        releaseTasks.removeValue(forKey: code)?.cancel()
        pressedAt[code] = .now
        pressedKeys.insert(code)
        lastPressedKey = code
        updateModifiers(modifiers)
    }

    func release(_ code: Int, modifiers: UIKeyModifierFlags) {
        updateModifiers(modifiers)
        let began = pressedAt.removeValue(forKey: code) ?? .now
        releaseTasks.removeValue(forKey: code)?.cancel()
        releaseTasks[code] = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: began + .milliseconds(90)) }
            catch { return }
            self?.pressedKeys.remove(code)
            self?.releaseTasks.removeValue(forKey: code)
        }
    }

    func reset() {
        releaseTasks.values.forEach { $0.cancel() }
        releaseTasks.removeAll()
        pressedAt.removeAll()
        pressedKeys.removeAll()
        lastPressedKey = nil
        shiftHeld = false
        capsLock = false
    }

    func synchronizeModifiers(_ modifiers: UIKeyModifierFlags) { updateModifiers(modifiers) }

    private func updateModifiers(_ modifiers: UIKeyModifierFlags) {
        shiftHeld = modifiers.contains(.shift)
        capsLock = modifiers.contains(.alphaShift)
    }
}

enum RemoteKeyboardHID {
    static func code(for character: Character) -> Int? {
        let value = String(character).lowercased()
        if let index = "abcdefghijklmnopqrstuvwxyz".firstIndex(of: Character(value)) {
            return 4 + "abcdefghijklmnopqrstuvwxyz".distance(from: "abcdefghijklmnopqrstuvwxyz".startIndex, to: index)
        }
        let symbols: [String: Int] = ["1":30,"2":31,"3":32,"4":33,"5":34,"6":35,"7":36,"8":37,"9":38,"0":39,
            "!":30,"@":31,"#":32,"$":33,"%":34,"^":35,"&":36,"*":37,"(":38,")":39,
            "-":45,"_":45,"=":46,"+":46,"[":47,"{":47,"]":48,"}":48,"\\":49,"|":49,
            ";":51,":":51,"'":52,"\"":52,"`":53,"~":53,",":54,"<":54,".":55,">":55,"/":56,"?":56," ":44]
        return symbols[value]
    }
}
