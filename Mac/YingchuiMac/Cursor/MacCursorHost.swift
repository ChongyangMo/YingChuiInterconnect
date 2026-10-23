import AppKit
import YingchuiProtocol

extension MacHostModel {
    /// 准备成功后才关闭视频中的光标；旧客户端继续使用嵌入式光标。
    func prepareCursor(for session: HostPeerSession, requestID: UUID, displayID: CGDirectDisplayID,
                       completion: @escaping @Sendable (RemoteCursorState?) -> Void) {
        guard session.supportsCursor else { completion(nil); return }
        let generation = UUID()
        cursorGeneration.set(generation)
        Task { @MainActor [weak self, weak session] in
            guard let self, let session, self.cursorGeneration.value == generation else { return }
            self.cursorMonitor?.stop()
            let monitor = MacCursorMonitor(displayID: displayID)
            do {
                let state = try monitor.prepare()
                self.cursorMonitor = monitor
                monitor.onFailure = { [weak self, weak session] error in
                    self?.networkQueue.async { [weak self, weak session] in
                        guard let self, let session, self.cursorGeneration.value == generation else { return }
                        self.failCursor(error, session: session, requestID: requestID)
                    }
                }
                self.networkQueue.async { [weak self, weak session] in
                    guard let self, let session, self.cursorGeneration.value == generation,
                          session.streamRequestID == requestID else { return }
                    self.eventLog.record("独立光标已就绪：位置按 60 帧采样，图形按变化同步")
                    completion(state)
                }
            } catch {
                monitor.stop()
                self.networkQueue.async { [weak self, weak session] in
                    guard let self, let session, self.cursorGeneration.value == generation else { return }
                    self.failCursor(error.localizedDescription, session: session, requestID: requestID)
                }
            }
        }
    }

    func startCursorUpdates(for session: HostPeerSession, requestID: UUID, streamID: UUID) {
        guard session.supportsCursor else { return }
        let generation = cursorGeneration.value
        Task { @MainActor [weak self, weak session] in
            guard let self, let session, self.cursorGeneration.value == generation,
                  let monitor = self.cursorMonitor else { return }
            monitor.onUpdate = { [weak self, weak session] state in
                self?.networkQueue.async { [weak self, weak session] in
                    guard let self, let session, self.streamingSessionID == session.id,
                          session.streamID == streamID, session.streamRequestID == requestID else { return }
                    session.sendCursor(state, streamID: streamID)
                }
            }
            monitor.start()
        }
    }

    func stopCursorUpdates() {
        let generation = UUID()
        cursorGeneration.set(generation)
        Task { @MainActor [weak self] in
            guard let self, self.cursorGeneration.value == generation else { return }
            self.cursorMonitor?.stop()
            self.cursorMonitor = nil
        }
    }

    private func failCursor(_ error: String, session: HostPeerSession, requestID: UUID) {
        eventLog.record("独立光标失败：\(error)")
        session.send(WireMessage(id: requestID, kind: .error, detail: "stream_runtime_failed", errorMessage: error))
        stopStreaming()
        publishStreamStatus(error, isStreaming: false)
    }

    func handleCursorInput(_ input: RemoteCursorInput, message: WireMessage, session: HostPeerSession) {
        guard session.supportsCursor, streamingSessionID == session.id,
              let streamID = session.streamID, message.streamID == streamID,
              input.sequence > session.lastCursorInputSequence else {
            rejectInvalidControlMessage(session, messageID: message.id, reason: "光标输入所属画面或序号无效")
            return
        }
        guard let current = CGEvent(source: nil)?.location,
              let event = MacPointerEventFactory.movement(from: current,
                deltaX: input.position.x - current.x, deltaY: input.position.y - current.y,
                buttons: session.remoteButtonState) else {
            rejectInvalidControlMessage(session, messageID: message.id, reason: "创建光标定位事件失败")
            return
        }
        event.setIntegerValueField(.eventSourceUserData, value: input.eventTag)
        event.post(tap: .cghidEventTap)
        session.lastCursorInputSequence = input.sequence
        screenStreamer.recordRemoteInteraction()
        session.send(WireMessage(id: message.id, kind: .controlAck))
    }
}
