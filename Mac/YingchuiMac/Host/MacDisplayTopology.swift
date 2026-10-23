import Foundation
import YingchuiProtocol

extension MacHostModel {
    func publishDisplayState(_ state: RemoteDisplayState) {
        eventLog.recordChange("显示模式已生效：\(state.mode.title)\(state.placement.map { "，" + $0.title } ?? "")", key: "显示模式")
        Task { @MainActor [weak self] in self?.activeDisplayState = state }
    }

    func scheduleDisplayTopologyReconciliation() {
        displayTopologyWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.displayTopologyWorkItem = nil
            self?.reconcileDisplayTopology()
        }
        displayTopologyWorkItem = work
        networkQueue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func reconcileDisplayTopology() {
        do {
            try virtualDisplayManager.reconcileDisplays()
            if let id = streamingSessionID, let session = sessions[id],
               let streamID = session.streamID, let requestID = session.streamRequestID {
                try virtualDisplayManager.arrange(placement: streamDisplayPlacement)
                let state = try virtualDisplayManager.confirmedState(placement: streamDisplayPlacement)
                publishDisplayState(state)
                session.send(WireMessage(id: requestID, kind: .displayState, streamID: streamID, displayState: state))
            }
            let pending = virtualDisplayManager.hasPendingRecovery
            Task { @MainActor [weak self] in self?.hasPendingDisplayRecovery = pending }
        } catch {
            // 真实的恢复错误必须停止回传并保留恢复记录。
            let status = "显示器切换失败：\(error.localizedDescription)"
            if let id = streamingSessionID, let session = sessions[id] {
                session.send(WireMessage(id: session.streamRequestID ?? UUID(), kind: .error, detail: "stream_runtime_failed", errorMessage: status))
            }
            stopStreaming(preservingVirtualDisplay: true)
            publishStreamStatus(status, isStreaming: false)
        }
    }

    func handleCaptureTermination(status: String, cause: MacStreamStopCause,
                                  message: WireMessage, session: HostPeerSession) {
        if cause == .capture {
            // 系统的采集终止回调可能先于显示器离线通知，等待这次拓扑变更完成。
            networkQueue.asyncAfter(deadline: .now() + 0.3) { [weak self, weak session] in
                guard let self, let session, self.streamingSessionID == session.id,
                      session.streamRequestID == message.id else { return }
                self.finishCaptureTermination(status: status, cause: cause, message: message, session: session)
            }
        } else {
            finishCaptureTermination(status: status, cause: cause, message: message, session: session)
        }
    }

    private func finishCaptureTermination(status: String, cause: MacStreamStopCause,
                                          message: WireMessage, session: HostPeerSession) {
        do {
            if cause == .capture, try virtualDisplayManager.consumeCaptureRestartAfterDisplayChange() {
                eventLog.record("显示器切换导致屏幕采集中断，保留控制连接并重建虚拟屏采集：\(status)")
                // 一次显示器切换只恢复一次采集；失败后正常报错，不循环重试。
                handleStreamStart(message, from: session, preservingDisplayMode: true)
                return
            }
        } catch {
            eventLog.record("检查拔线后的采集恢复失败：\(error.localizedDescription)")
        }
        streamingSessionID = nil
        releaseStreamPowerActivity()
        virtualDisplayManager.deactivate(after: 12)
        session.send(WireMessage(id: message.id, kind: .error, detail: cause == .codec ? "video_codec_failed" : "stream_runtime_failed", errorMessage: status))
        publishStreamStatus(status, isStreaming: false)
    }
}
