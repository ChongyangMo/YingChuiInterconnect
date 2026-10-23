import SwiftUI
import YingchuiProtocol

struct PadConnectionHeader: View {
    @AppStorage(PadSettings.developerModeKey) private var developerMode = false
    @ObservedObject var model: PadConnectionModel
    let onForget: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.isPaired ? "macmini.fill" : "macmini")
                .font(.system(size: 26))
                .foregroundStyle(model.isPaired ? .green : .secondary)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.connectedHostName ?? "尚未连接")
                    .font(.title3.bold())
                    .lineLimit(1)
                Text(model.statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if developerMode, let rtt = model.roundTripMilliseconds {
                Label(
                    "\(rtt.formatted(.number.precision(.fractionLength(1)))) ms",
                    systemImage: "waveform.path.ecg"
                )
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(rtt <= 15 ? .green : .orange)
            }

            if model.requiresAllTrustReset || (model.connectedHostName != nil && !model.isPaired && model.canResetCurrentHostTrust) {
                Button(model.requiresAllTrustReset ? "重置全部信任" : "重置信任", action: onForget)
                    .buttonStyle(.yingchuiSecondary)
                    .frame(minHeight: 44)
            } else if model.isConnected {
                Button("断开") { model.disconnect() }
                    .buttonStyle(.yingchuiSecondary)
                    .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct PadPairingCard: View {
    @ObservedObject var model: PadConnectionModel
    @Binding var pairingCode: String
    @ScaledMetric(relativeTo: .title2) private var pairingCodeSize = 22

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                introduction
                Spacer(minLength: 8)
                input
            }
            VStack(spacing: 12) {
                introduction
                input
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("首次设备配对", systemImage: "lock.shield")
                .font(.headline)
            Text(model.pairingMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var input: some View {
        HStack(spacing: 8) {
            TextField("六位配对码", text: $pairingCode)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.system(size: pairingCodeSize, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .frame(minHeight: 44)
                .onChange(of: pairingCode) { _, value in
                    pairingCode = String(value.filter(\.isNumber).prefix(6))
                }

            Button { model.submitPairingCode(pairingCode) } label: {
                YingchuiActionLabel(title: "配对", systemImage: "lock.open", isWorking: model.isPairing)
            }
                .buttonStyle(.yingchuiPrimary)
                .disabled(pairingCode.count != 6 || model.isPairing)
                .frame(minHeight: 44)
        }
    }
}

struct PadVideoPanel: View {
    @AppStorage(PadControlMode.preferenceKey) private var controlMode: PadControlMode = .mouseKeyboard
    @ObservedObject var model: PadConnectionModel
    @Binding var isFullScreen: Bool

    var body: some View {
        VStack(spacing: 10) {
            PadVideoToolbar(model: model, isFullScreen: $isFullScreen)

            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(.black)
                if model.isStreaming && !isFullScreen {
                    let streamID = model.activeStreamID
                    ZoomableVideoPreview(renderer: model.videoRenderer, aspectRatio: model.videoAspectRatio,
                        streamID: streamID,
                        touchEnabled: controlMode == .touch && model.isPaired && model.videoIsPlaying
                            && !model.displayModeChanging && model.supportsDirectTouch
                    ) { input in
                        if let streamID { model.sendTouch(input, streamID: streamID) }
                    }
                    .overlay {
                        if controlMode == .touch && model.isPaired && !model.supportsDirectTouch {
                            Text("请更新 Mac 以使用触摸控制").font(.callout)
                                .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "rectangle.slash")
                            .font(.system(size: 36))
                        Text("点击开始回传以查看 Mac 画面")
                    }
                    .foregroundStyle(.white.opacity(0.7))
                }
            }
            .aspectRatio(model.videoAspectRatio ?? (16 / 9), contentMode: .fit)
            .overlay(alignment: .top) {
                if model.isStreaming && model.isConnected && !isFullScreen {
                    PadStreamMetricsView(metrics: model.streamMetrics).padding(8)
                }
            }

            HStack {
                Text(model.streamStatusText)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .font(.caption)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct PadControlPanel: View {
    @ObservedObject var model: PadConnectionModel
    @Binding var textToSend: String
    let isRemoteDragging: Bool
    let onDraggingChanged: (Bool) -> Void

    var body: some View {
        VStack(spacing: 12) {
            TrackpadView(
                onMove: { model.sendPointerDelta(x: $0, y: $1) },
                onTap: { model.sendMouseClick(button: .left) },
                onRightTap: { model.sendMouseClick(button: .right) },
                onScroll: { model.sendScroll(deltaX: $0, deltaY: $1) },
                onDragChanged: onDraggingChanged
            )

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    pointerButtons
                    Spacer()
                    shortcutMenu
                    scrollButtons
                }
                VStack(spacing: 8) {
                    pointerButtons
                    HStack(spacing: 8) {
                        shortcutMenu
                        scrollButtons
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("输入要发送到 Mac 的文字", text: $textToSend)
                    .textFieldStyle(.roundedBorder)
                    .frame(minHeight: 44)
                    .onSubmit(sendText)
                Button("发送", systemImage: "paperplane", action: sendText)
                    .buttonStyle(.yingchuiPrimary)
                    .disabled(textToSend.isEmpty)
                    .frame(minHeight: 44)
            }
        }
        .padding(.bottom, 12)
    }

    private var pointerButtons: some View {
        HStack(spacing: 8) {
            Button("左键", systemImage: "cursorarrow.click") {
                model.sendMouseClick(button: .left)
            }
            .buttonStyle(.yingchuiPrimary)
            .frame(minHeight: 44)

            Button("右键", systemImage: "contextualmenu.and.cursorarrow") {
                model.sendMouseClick(button: .right)
            }
            .buttonStyle(.yingchuiSecondary)
            .frame(minHeight: 44)

            Button(isRemoteDragging ? "松开" : "拖拽", systemImage: "hand.point.up.left") {
                onDraggingChanged(!isRemoteDragging)
            }
            .buttonStyle(.yingchuiSecondary)
            .tint(isRemoteDragging ? .accentColor : .secondary)
            .frame(minHeight: 44)
        }
    }

    private var shortcutMenu: some View {
        Menu("快捷键", systemImage: "command") {
            Button("撤销") { model.sendKeyPress(.letterZ, modifiers: [.command]) }
            Button("重做") { model.sendKeyPress(.letterZ, modifiers: [.command, .shift]) }
            Divider()
            Button("复制") { model.sendKeyPress(.letterC, modifiers: [.command]) }
            Button("粘贴") { model.sendKeyPress(.letterV, modifiers: [.command]) }
            Button("剪切") { model.sendKeyPress(.letterX, modifiers: [.command]) }
            Button("全选") { model.sendKeyPress(.letterA, modifiers: [.command]) }
            Divider()
            Button("关闭窗口") { model.sendKeyPress(.letterW, modifiers: [.command]) }
            Button("Escape") { model.sendKeyPress(.escape) }
        }
        .frame(minHeight: 44)
    }

    private var scrollButtons: some View {
        HStack(spacing: 8) {
            Button("向上", systemImage: "chevron.up") { model.sendScroll(deltaY: 80) }
                .frame(minHeight: 44)
            Button("向下", systemImage: "chevron.down") { model.sendScroll(deltaY: -80) }
                .frame(minHeight: 44)
        }
    }

    private func sendText() {
        model.sendText(textToSend)
        textToSend = ""
    }
}
