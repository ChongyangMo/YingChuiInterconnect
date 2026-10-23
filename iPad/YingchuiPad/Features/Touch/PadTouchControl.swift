import SwiftUI
import YingchuiProtocol

enum PadControlMode: String, CaseIterable, Identifiable {
    case mouseKeyboard, touch
    var id: String { rawValue }
    var title: String { self == .touch ? "触摸" : "鼠标键盘" }
    static let preferenceKey = "YingchuiControlMode"
}

struct PadControlModePicker: View {
    var showsHelp = false
    @AppStorage(PadControlMode.preferenceKey) private var mode: PadControlMode = .mouseKeyboard
    var body: some View {
        HStack(spacing: 12) {
            if showsHelp {
                PadSettingsHelpLabel(topic: .controlMode)
                Spacer(minLength: 0)
            }
            Picker("操作方式", selection: $mode) {
                ForEach(PadControlMode.allCases) { Text($0.title).tag($0) }
            }
            .modifier(PadControlPickerLabel(hidden: showsHelp))
            .accessibilityIdentifier("control-mode-picker")
        }
    }
}

struct PadVideoInteractionSurface: View {
    @ObservedObject var model: PadConnectionModel
    @AppStorage(PadControlMode.preferenceKey) private var mode: PadControlMode = .mouseKeyboard

    var body: some View {
        if mode == .touch {
            let streamID = model.activeStreamID
            DirectTouchSurface(aspectRatio: model.videoAspectRatio, streamID: streamID,
                enabled: model.isPaired && model.videoIsPlaying && !model.displayModeChanging && model.supportsDirectTouch
            ) { touch in
                if let streamID { model.sendTouch(touch, streamID: streamID) }
            }
            .overlay {
                if model.isPaired && !model.supportsDirectTouch {
                    Text("请更新 Mac 以使用触摸控制").font(.callout)
                        .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        } else {
            RemoteGestureSurface(
                streamID: model.activeStreamID,
                enabled: model.isPaired && model.videoIsPlaying && !model.displayModeChanging,
                onMove: { model.sendPointerDelta(x: $0, y: $1) },
                onTap: { model.sendMouseClick(button: .left) },
                onRightTap: { model.sendMouseClick(button: .right) },
                onScroll: { model.sendScroll(deltaX: $0, deltaY: $1) },
                onDragChanged: { model.sendMouseButton(button: .left, pressed: $0) }
            )
        }
    }
}

extension PadConnectionModel {
    @MainActor
    func sendTouch(_ touch: RemoteTouchInput, streamID: UUID) {
        guard isPaired, activeStreamID == streamID else { return }
        guard supportsDirectTouch else { statusText = "请更新 Mac 以使用触摸控制"; return }
        guard touch.phase != .hover || supportsTouchHover else {
            statusText = "请更新 Mac 以使用触摸悬停"
            return
        }
        do { try touch.validate() }
        catch { statusText = error.localizedDescription; return }
        videoRenderer.prepareForInteraction()
        let cursorInput = videoRenderer.cursor.touch(touch)
        let epoch = connectionEpoch.value
        networkQueue.async { [weak self] in
            guard let self, self.connectionEpoch.value == epoch, self.activeStreamID == streamID,
                  self.wantsStreaming, let connection = self.connection else { return }
            self.flushPointerDelta()
            self.sendControl(WireMessage(kind: .touchInput, streamID: streamID, touch: touch, cursorInput: cursorInput), over: connection)
        }
    }
}

private struct PadControlPickerLabel: ViewModifier {
    let hidden: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if hidden { content.labelsHidden() } else { content }
    }
}
