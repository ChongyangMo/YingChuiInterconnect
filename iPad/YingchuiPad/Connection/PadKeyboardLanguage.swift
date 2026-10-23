import Foundation
import YingchuiProtocol

extension PadConnectionModel {
    @MainActor
    func toggleKeyboardLanguage() {
        guard isPaired else { transferStatus = "请先配对 Mac"; return }
        guard !keyboardLanguageChanging else { return }
        let language: RemoteKeyboardLanguage = remoteKeyboardLanguage == .pinyin ? .english : .pinyin
        keyboardLanguageChanging = true
        let epoch = connectionEpoch.value
        networkQueue.async { [weak self] in
            guard let self else { return }
            let message = WireMessage(kind: .keyboardLanguage, keyboardLanguage: language)
            self.pendingKeyboardLanguageRequest = message.id
            self.requestedKeyboardLanguage = language
            guard self.connectionEpoch.value == epoch, let connection = self.connection else {
                self.finishKeyboardLanguageChange(error: "连接已断开，输入法未切换")
                return
            }
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.pendingKeyboardLanguageRequest == message.id else { return }
                self.finishKeyboardLanguageChange(error: "Mac 输入法切换超时")
            }
            self.keyboardLanguageTimeout = timeout
            self.networkQueue.asyncAfter(deadline: .now() + 5, execute: timeout)
            self.sendControl(message, over: connection)
        }
    }

    func finishKeyboardLanguageChange(language: RemoteKeyboardLanguage? = nil, error: String? = nil) {
        let expected = requestedKeyboardLanguage
        pendingKeyboardLanguageRequest = nil
        requestedKeyboardLanguage = nil
        keyboardLanguageTimeout?.cancel()
        keyboardLanguageTimeout = nil
        let failure = error ?? (language == nil || language != expected ? "Mac 输入法切换回执无效" : nil)
        let epoch = connectionEpoch.value
        Task { @MainActor [weak self] in
            guard let self, self.connectionEpoch.value == epoch else { return }
            self.keyboardLanguageChanging = false
            if let failure { self.transferStatus = failure }
            else if let language {
                self.remoteKeyboardLanguage = language
                self.eventLog.record("Mac 已确认输入法：\(language == .pinyin ? "简体拼音" : "ABC")")
            }
        }
    }

    @MainActor
    func sendFloatingKeyboardText(_ text: String) {
        guard !keyboardLanguageChanging else { transferStatus = "正在切换 Mac 输入法，请稍后输入"; return }
        guard remoteKeyboardLanguage == .pinyin else { sendKeyboardText(text); return }
        let strokes = text.map { RemoteKeyboardStroke(character: $0) }
        if strokes.allSatisfy({ $0 != nil }) {
            for stroke in strokes.compactMap({ $0 }) { sendKeyPress(stroke.key, modifiers: stroke.modifiers) }
        } else {
            // 本地系统输入法已经确认的中文或表情仍按真实 Unicode 提交。
            sendKeyboardText(text)
        }
    }
}
