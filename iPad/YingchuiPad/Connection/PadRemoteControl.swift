import CryptoKit
import Foundation
import Network
import Security
import UIKit
import YingchuiProtocol

extension PadConnectionModel {
    @MainActor
    func sendPointerDelta(x: Double, y: Double) {
        guard isPaired else { return }
        guard x.isFinite, y.isFinite else { statusText = "鼠标移动坐标无效"; return }
        videoRenderer.prepareForInteraction()
        let epoch = connectionEpoch.value
        let cursorInput = videoRenderer.cursor.move(deltaX: x, deltaY: y)
        let cursorStreamID = videoRenderer.cursor.streamID
        let enteredAt = DispatchTime.now().uptimeNanoseconds
        networkQueue.async { [weak self] in
            guard let self, self.connectionEpoch.value == epoch, self.connection != nil else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            self.controlPipelineMetrics.queueWait.record(from: enteredAt, to: now)
            if let cursorInput, let cursorStreamID {
                guard self.activeStreamID == cursorStreamID else { return }
                self.pendingCursorInput = cursorInput
                self.pendingCursorStreamID = cursorStreamID
            } else {
                self.pendingPointerX += x
                self.pendingPointerY += y
            }
            guard self.pointerFlushID == nil else { return }
            let flushID = UUID()
            self.pointerFlushID = flushID
            self.controlPipelineMetrics.firstPendingMove = now
            self.networkQueue.asyncAfter(deadline: .now() + .milliseconds(2)) { [weak self] in
                guard let self, self.connectionEpoch.value == epoch, self.pointerFlushID == flushID else { return }
                self.flushPointerDelta()
            }
        }
    }

    @MainActor
    func sendMouseClick(button: PointerButton) {
        sendMouseButton(button: button, pressed: true)
        sendMouseButton(button: button, pressed: false)
    }

    @MainActor
    func sendMouseButton(button: PointerButton, pressed: Bool) {
        guard isPaired else { return }
        videoRenderer.prepareForInteraction()
        let cursorInput = videoRenderer.cursor.buttonInput()
        let cursorStreamID = videoRenderer.cursor.streamID
        let epoch = connectionEpoch.value
        networkQueue.async { [weak self] in
            guard let self, self.connectionEpoch.value == epoch, let connection = self.connection else { return }
            if let cursorStreamID, self.activeStreamID != cursorStreamID { return }
            // 按下前先定位，松开前先送完拖动，避免拖拽终点丢失。
            self.flushPointerDelta()
            self.sendControl(WireMessage(kind: .mouseButton, button: button, pressed: pressed, streamID: cursorStreamID, cursorInput: cursorInput), over: connection)
        }
    }

    @MainActor
    func sendScroll(deltaX: Double = 0, deltaY: Double) {
        guard isPaired else { return }
        videoRenderer.prepareForInteraction()
        let epoch = connectionEpoch.value
        networkQueue.async { [weak self] in
            guard let self, self.connectionEpoch.value == epoch, let connection = self.connection else { return }
            self.flushPointerDelta()
            self.sendControl(WireMessage(kind: .scroll, deltaX: deltaX, deltaY: deltaY), over: connection)
        }
    }

    @MainActor
    func sendText(_ text: String) { _ = submitText(text) }

    @MainActor
    @discardableResult
    func submitText(_ text: String) -> Bool {
        guard isPaired else { transferStatus = "请先配对 Mac"; return false }
        do {
            let chunks = try RemoteTextPolicy.chunks(text)
            videoRenderer.prepareForInteraction()
            transferStatus = "正在发送文字"
            let epoch = connectionEpoch.value
            networkQueue.async { [weak self] in
                guard let self, self.connectionEpoch.value == epoch else { return }
                guard self.pendingTextIDs.isEmpty else { self.publishTransferStatus("上一条文字尚未确认，请稍后发送"); return }
                guard let connection = self.connection else { self.publishTransferStatus("连接已断开，文字未发送"); return }
                for chunk in chunks {
                    let message = WireMessage(kind: .textInput, text: chunk)
                    self.pendingTextIDs.insert(message.id)
                    self.sendControl(message, over: connection)
                }
            }
            return true
        } catch { transferStatus = error.localizedDescription; return false }
    }

    @MainActor
    func sendKeyPress(_ key: RemoteKey, modifiers: [RemoteKeyModifier] = []) {
        guard isPaired else { return }
        videoRenderer.prepareForInteraction()
        networkQueue.async { [weak self] in
            guard let self, let connection = self.connection else { return }
            self.sendControl(WireMessage(kind: .keyPress, key: key, modifiers: modifiers), over: connection)
        }
    }

    func flushPointerDelta() {
        pointerFlushID = nil
        if let first = controlPipelineMetrics.firstPendingMove {
            controlPipelineMetrics.mergeWait.record(from: first, to: DispatchTime.now().uptimeNanoseconds)
            controlPipelineMetrics.firstPendingMove = nil
        }
        let cursorInput = pendingCursorInput
        let cursorStreamID = pendingCursorStreamID
        pendingCursorInput = nil
        pendingCursorStreamID = nil
        let x = pendingPointerX
        let y = pendingPointerY
        pendingPointerX = 0
        pendingPointerY = 0
        if let connection, let cursorInput, let cursorStreamID, activeStreamID == cursorStreamID {
            sendControl(WireMessage(kind: .pointerMove, streamID: cursorStreamID, cursorInput: cursorInput), over: connection)
            return
        }
        guard let connection, abs(x) + abs(y) > 0.01 else { return }
        sendControl(WireMessage(kind: .pointerMove, deltaX: x, deltaY: y), over: connection)
    }

    func sendControl(_ message: WireMessage, over activeConnection: NWConnection) {
        let now = DispatchTime.now().uptimeNanoseconds
        if controlAcknowledgements.begin(id: message.id, at: now) > 0,
           !didReportControlAcknowledgementTimeout {
            didReportControlAcknowledgementTimeout = true
            publishStatus("控制执行回执超时，请检查连接")
        }
        send(message, over: activeConnection)
    }
}
