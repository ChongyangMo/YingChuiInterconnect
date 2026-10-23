import Foundation
import YingchuiProtocol

extension PadConnectionModel {
    @MainActor
    func selectDisplayMode(_ mode: RemoteDisplayMode) {
        guard mode != .standalone else { return }
        let reapply = isStreaming && activeDisplayState?.mode != mode
        guard selectedDisplayMode != mode || reapply else { return }
        selectedDisplayMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "YingchuiDisplayMode")
        if isStreaming { scheduleStreamReconfiguration(quality: activeQuality, status: "正在切换显示模式", force: reapply) }
    }

    @MainActor
    func selectDisplayPlacement(_ placement: RemoteDisplayPlacement) {
        guard displayPlacement != placement else { return }
        displayPlacement = placement
        UserDefaults.standard.set(placement.rawValue, forKey: "YingchuiDisplayPlacement")
        if isStreaming { scheduleStreamReconfiguration(quality: activeQuality, status: "正在调整屏幕位置") }
    }

    @MainActor
    var displayModeTitle: String {
        if displayModeChanging { return "正在切换" }
        return activeDisplayState?.mode.title ?? selectedDisplayMode.title
    }

    func handleDisplayState(_ message: WireMessage) {
        guard wantsStreaming, !videoConfigurationPending,
              videoRequestID.value == message.id,
              let streamID = message.streamID, activeStreamID == streamID else { return }
        guard let state = message.displayState, state.isValid else {
            finishStreamingFailure("Mac 返回了无效的显示状态")
            return
        }
        Task { @MainActor [weak self] in
            guard let self, self.wantsStreaming, self.videoRequestID.value == message.id,
                  self.activeStreamID == streamID else { return }
            self.activeDisplayState = state
        }
    }

    @MainActor
    func returnPointerToDisplay() {
        guard isPaired, isStreaming, !displayModeChanging else { return }
        networkQueue.async { [weak self] in
            guard let self, let connection = self.connection, let streamID = self.activeStreamID else { return }
            self.sendControl(WireMessage(kind: .pointerReturn, streamID: streamID), over: connection)
        }
    }
}
