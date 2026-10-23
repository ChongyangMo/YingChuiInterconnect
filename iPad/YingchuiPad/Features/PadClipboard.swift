import Foundation
import UIKit
import YingchuiProtocol

extension PadConnectionModel {
    @MainActor
    func sendClipboard() {
        guard isPaired else { transferStatus = "请先配对 Mac"; return }
        do { beginClipboard(.clipboardSet, text: try RemoteTextPolicy.validateClipboard(UIPasteboard.general.string)) }
        catch { transferStatus = error.localizedDescription }
    }

    @MainActor
    func receiveClipboard() {
        guard isPaired else { transferStatus = "请先配对 Mac"; return }
        beginClipboard(.clipboardGet, text: nil)
    }

    @MainActor
    private func beginClipboard(_ kind: WireMessageKind, text: String?) {
        transferStatus = "正在传送剪贴板"
        let epoch = connectionEpoch.value
        networkQueue.async { [weak self] in
            guard let self, self.connectionEpoch.value == epoch else { return }
            guard let connection = self.connection else { self.publishTransferStatus("连接已断开，剪贴板未传送"); return }
            guard self.pendingClipboardRequest == nil else {
                self.publishTransferStatus("剪贴板请求尚未完成")
                return
            }
            let request = WireMessage(kind: kind, text: text)
            self.pendingClipboardRequest = (request.id, kind)
            self.send(request, over: connection)
            self.networkQueue.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.pendingClipboardRequest?.id == request.id else { return }
                self.pendingClipboardRequest = nil
                self.publishTransferStatus("剪贴板传送超时")
            }
        }
    }

    func handleClipboardResult(_ message: WireMessage) {
        guard let request = pendingClipboardRequest, request.id == message.id else {
            eventLog.record("已拒绝未请求的剪贴板响应")
            return
        }
        pendingClipboardRequest = nil
        guard message.accepted == true else {
            publishTransferStatus(message.errorMessage ?? "剪贴板操作失败")
            return
        }
        let epoch = connectionEpoch.value
        if request.kind == .clipboardGet {
            do {
                let text = try RemoteTextPolicy.validateClipboard(message.text)
                Task { @MainActor [weak self] in
                    guard let self, self.connectionEpoch.value == epoch else { return }
                    UIPasteboard.general.string = text
                    self.transferStatus = "已复制 Mac 剪贴板"
                }
            } catch { publishTransferStatus(error.localizedDescription) }
        } else { publishTransferStatus("已发送到 Mac 剪贴板") }
    }

    func publishTransferStatus(_ status: String) {
        let epoch = connectionEpoch.value
        Task { @MainActor [weak self] in
            guard let self, self.connectionEpoch.value == epoch else { return }
            self.transferStatus = status
        }
    }
}
