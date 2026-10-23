import Foundation
import YingchuiProtocol

extension PadConnectionModel {
    func handleCursorState(_ message: WireMessage) {
        guard wantsStreaming, let streamID = message.streamID, streamID == activeStreamID else { return }
        guard let state = message.cursorState, state.isValid else {
            finishStreamingFailure("Mac 光标同步数据无效")
            return
        }
        let receivedAt = DispatchTime.now().uptimeNanoseconds
        let epoch = connectionEpoch.value
        Task { @MainActor [weak self] in
            guard let self, self.connectionEpoch.value == epoch, self.activeStreamID == streamID else { return }
            self.videoRenderer.cursor.diagnostics.mainWait.record(from: receivedAt, to: DispatchTime.now().uptimeNanoseconds)
            do { try self.videoRenderer.cursor.apply(state, streamID: streamID) }
            catch {
                self.networkQueue.async { [weak self] in
                    guard let self, self.activeStreamID == streamID else { return }
                    self.finishStreamingFailure(error.localizedDescription)
                }
            }
        }
    }
}
