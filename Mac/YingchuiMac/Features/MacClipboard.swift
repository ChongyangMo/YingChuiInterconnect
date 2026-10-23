import AppKit
import YingchuiProtocol

extension MacHostModel {
    func handleClipboard(_ message: WireMessage, from session: HostPeerSession) {
        guard session.isAuthorized, claimController(session) else {
            session.send(WireMessage(id: message.id, kind: .clipboardResult, accepted: false,
                                     errorMessage: "设备未授权或 Mac 正由其他设备控制"))
            return
        }
        Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            // 真正读取前再次在串行队列确认授权，撤销操作不会留下排队的剪贴板访问。
            let authorized = self.networkQueue.sync { session.isAuthorized && self.sessions[session.id] != nil }
            guard authorized else { return }
            let response: WireMessage
            do {
                if message.kind == .clipboardGet {
                    let text = try RemoteTextPolicy.validateClipboard(NSPasteboard.general.string(forType: .string))
                    response = WireMessage(id: message.id, kind: .clipboardResult, accepted: true, text: text)
                } else {
                    let text = try RemoteTextPolicy.validateClipboard(message.text)
                    NSPasteboard.general.clearContents()
                    guard NSPasteboard.general.setString(text, forType: .string) else { throw MacClipboardError.writeFailed }
                    response = WireMessage(id: message.id, kind: .clipboardResult, accepted: true)
                }
            } catch {
                response = WireMessage(id: message.id, kind: .clipboardResult, accepted: false,
                                       errorMessage: error.localizedDescription)
            }
            self.networkQueue.async { [weak self, weak session] in
                guard let self, let session, session.isAuthorized, self.sessions[session.id] != nil else { return }
                session.send(response)
            }
        }
    }
}

private enum MacClipboardError: LocalizedError {
    case writeFailed
    var errorDescription: String? { "写入 Mac 剪贴板失败" }
}
