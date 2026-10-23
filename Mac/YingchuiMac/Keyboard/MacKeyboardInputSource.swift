import Carbon
import Foundation
import YingchuiProtocol

enum MacKeyboardInputSource {
    static func select(_ language: RemoteKeyboardLanguage) throws {
        if Thread.isMainThread { try selectOnMain(language) }
        else { try DispatchQueue.main.sync { try selectOnMain(language) } }
    }

    static func identifier(for language: RemoteKeyboardLanguage) -> String {
        language == .pinyin ? "com.apple.inputmethod.SCIM.ITABC" : "com.apple.keylayout.ABC"
    }

    private static func selectOnMain(_ language: RemoteKeyboardLanguage) throws {
        let identifier = identifier(for: language)
        let filter = [kTISPropertyInputSourceID: identifier] as CFDictionary
        let sources = TISCreateInputSourceList(filter, false).takeRetainedValue() as NSArray
        guard let source = sources.firstObject as! TISInputSource? else {
            throw MacKeyboardInputSourceError.unavailable(language)
        }
        let status = TISSelectInputSource(source)
        guard status == noErr else { throw MacKeyboardInputSourceError.selectionFailed(status) }
    }
}

enum MacKeyboardInputSourceError: LocalizedError {
    case unavailable(RemoteKeyboardLanguage)
    case selectionFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unavailable(let language):
            let name = language == .pinyin ? "简体拼音" : "ABC"
            return "Mac 未启用\(name)输入法，请在系统设置的键盘输入法中添加"
        case .selectionFailed(let status):
            return "Mac 输入法切换失败：\(status)"
        }
    }
}
