import Foundation
import YingchuiProtocol

extension MacHostModel {
    @MainActor
    func restoreDisplayConfiguration() {
        networkQueue.async { [weak self] in
            guard let self else { return }
            if let id = self.streamingSessionID, let session = self.sessions[id] {
                session.send(WireMessage(kind: .error, detail: "stream_stopped_by_host"))
            }
            self.stopStreaming(preservingVirtualDisplay: true)
            do {
                try self.virtualDisplayManager.restoreSavedConfiguration()
                self.publishStatus("已恢复 Mac 显示器配置")
            } catch { self.publishStatus("恢复显示器失败：\(error.localizedDescription)") }
            let pending = self.virtualDisplayManager.hasPendingRecovery
            Task { @MainActor [weak self] in self?.hasPendingDisplayRecovery = pending }
        }
    }
}
