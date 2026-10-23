import Foundation
import YingchuiProtocol

extension HostPeerSession {
    /// 通道忙时只留最新位置，但保留尚未送出的形状变化，避免追赶过期光标。
    func sendCursor(_ state: RemoteCursorState, streamID: UUID) {
        guard self.streamID == streamID, supportsCursor, !isSuperseded else { return }
        if cursorSendInFlight {
            pendingCursorState = RemoteCursorState(position: state.position, captureBounds: state.captureBounds,
                displays: state.displays, visible: state.visible, acknowledgedInput: state.acknowledgedInput,
                shape: state.shape ?? pendingCursorState?.shape)
            return
        }
        cursorSendInFlight = true
        send(WireMessage(kind: .cursorState, streamID: streamID, cursorState: state)) { [weak self] in
            guard let self, self.streamID == streamID else { return }
            self.cursorSendInFlight = false
            if let pending = self.pendingCursorState {
                self.pendingCursorState = nil
                self.sendCursor(pending, streamID: streamID)
            }
        }
    }
}
