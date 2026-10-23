import Foundation
import YingchuiProtocol

extension PadConnectionModel {
    /// 连续打字不等待上一字回执；与删除、回车共用串行控制队列保持顺序。
    @MainActor
    func sendKeyboardText(_ text: String) {
        guard isPaired else { transferStatus = "请先配对 Mac"; return }
        do {
            let chunks = try RemoteTextPolicy.chunks(text)
            let epoch = connectionEpoch.value
            networkQueue.async { [weak self] in
                guard let self else { return }
                guard self.connectionEpoch.value == epoch, let connection = self.connection else {
                    self.publishTransferStatus("连接已断开，键盘输入未发送")
                    return
                }
                for chunk in chunks {
                    self.sendControl(WireMessage(kind: .textInput, text: chunk), over: connection)
                }
            }
        } catch { transferStatus = error.localizedDescription }
    }
}
