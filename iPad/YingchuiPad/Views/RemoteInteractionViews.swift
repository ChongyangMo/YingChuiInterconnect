import AVFoundation
import SwiftUI
import YingchuiProtocol

struct FullScreenVideoView: View {
    @Environment(\.displayScale) private var displayScale
    @ObservedObject var model: PadConnectionModel
    @Binding var isPresented: Bool
    @State private var showKeyboard = false

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            FullScreenVideoSurface(
                renderer: model.videoRenderer,
                onViewportChange: { size in
                    updateViewport(size, nativeScale: displayScale)
                }
            )

            PadVideoInteractionSurface(model: model)

            Group {
                if !model.videoIsPlaying || !model.isConnected {
                    VStack(spacing: 12) {
                        Text(model.isConnected ? model.streamStatusText : model.statusText)
                            .multilineTextAlignment(.center)
                        Button("重试") { model.retryPlayback() }.buttonStyle(.yingchuiPrimary)
                    }
                    .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding(24)
                    .transition(.opacity)
                }
            }
            .yingchuiStatusMotion(!model.videoIsPlaying || !model.isConnected)

            VStack {
                HStack(alignment: .top, spacing: 12) {
                    Button {
                        isPresented = false
                    } label: {
                        FullScreenControlIcon(systemName: "chevron.left")
                    }
                    .buttonStyle(.yingchuiPlain)
                    .accessibilityLabel("退出全屏")

                    Spacer()

                    if model.isStreaming && model.isConnected {
                        PadStreamMetricsView(metrics: model.streamMetrics)
                    }

                    Spacer()

                    PadMoreMenu(model: model, onExitFullScreen: { isPresented = false }) {
                        showKeyboard = true
                    }
                }
                .font(.subheadline)
                .padding()

                Spacer()
            }
        }
        .overlay(alignment: .bottom) { TransferStatusView(model: model) }
        .modifier(RemoteKeyboardPresentation(model: model, isPresented: $showKeyboard))
        .ignoresSafeArea(.container)
        .modifier(KeyboardPresentationSmokeTest(model: model, isPresented: $showKeyboard))
        .onAppear {
            model.requestKeyFrame()
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    private func updateViewport(_ size: CGSize, nativeScale: CGFloat) {
        model.refreshStreamingViewport(viewSize: size, nativeScale: nativeScale)
        model.recordFullScreenLayout(
            containerSize: size,
            streamViewportSize: size,
            nativeScale: nativeScale
        )
    }
}

struct FullScreenVideoSurface: View {
    let renderer: VideoRenderer
    let onViewportChange: (CGSize) -> Void

    var body: some View {
        // 可见画面跟随键盘安全区域缩放；编码视口始终读取完整窗口区域。
        // 两者分开，避免输入时重建显示器、解码器和声音链路。
        VideoSurfaceView(renderer: renderer, videoGravity: .resizeAspect)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                GeometryReader { viewport in
                    Color.clear
                        .onAppear { onViewportChange(viewport.size) }
                        .onChange(of: viewport.size) { _, size in onViewportChange(size) }
                }
                .ignoresSafeArea()
            }
    }
}

struct TrackpadView: View {
    let onMove: (Double, Double) -> Void
    let onTap: () -> Void
    let onRightTap: () -> Void
    let onScroll: (Double, Double) -> Void
    let onDragChanged: (Bool) -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(.quaternary)
            Label("触控板", systemImage: "hand.draw")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            RemoteGestureSurface(
                onMove: onMove,
                onTap: onTap,
                onRightTap: onRightTap,
                onScroll: onScroll,
                onDragChanged: onDragChanged
            )
        }
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .accessibilityLabel("触控板")
        .accessibilityHint("单指移动和点击，双指滚动和右键，长按后拖动")
    }
}
