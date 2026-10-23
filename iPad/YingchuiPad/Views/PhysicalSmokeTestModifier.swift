import SwiftUI

struct PhysicalSmokeTestModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var model: PadConnectionModel
    @Binding var isVideoFullScreen: Bool

    @State private var didRequestConnection = false
    @State private var didRequestStreaming = false
    @State private var didRequestFullScreen = false

    private let isEnabled: Bool = {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--physical-smoke-test")
#else
        false
#endif
    }()

    func body(content: Content) -> some View {
        content
#if DEBUG
            .modifier(CursorSmokeTest(model: model))
            .modifier(DisplayModeSmokeTest(model: model))
            .modifier(CaptureMenuSmokeTest(model: model))
            .modifier(VideoInvestigationSmokeTest(model: model))
            .modifier(DockInputSmokeTest(model: model))
#endif
            .onAppear(perform: advance)
            .onChange(of: scenePhase) { _, _ in advance() }
            .onChange(of: model.discoveredHosts) { _, _ in advance() }
            .onChange(of: model.isPaired) { _, _ in advance() }
            .onChange(of: model.videoAspectRatio) { _, _ in advance() }
            .onChange(of: model.videoIsPlaying) { _, _ in advance() }
            .onChange(of: model.statusText) { _, status in
                if isEnabled { print("实机自动测试：连接状态：\(status)") }
            }
            .onChange(of: model.streamStatusText) { _, status in
                if isEnabled { print("实机自动测试：视频状态：\(status)") }
            }
            .task {
                guard isEnabled else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    let audio = model.audioReceiver.playbackStatistics
                    print("实机自动测试：视频已解码 \(model.videoFramesDecoded) 帧，声音已渲染 \(audio.renderedFrames) 采样帧，声音待渲染 \(Int(audio.bufferedMilliseconds)) 毫秒，回传状态 \(model.isStreaming ? "运行" : "停止")")
                }
            }
    }

    private func advance() {
        guard isEnabled else { return }

        if model.connectedHostName == nil,
           !didRequestConnection,
           let host = model.discoveredHosts.first {
            didRequestConnection = true
            print("实机自动测试：正在连接 \(host.name)")
            model.connect(to: host)
            return
        }

        if model.isPaired,
           scenePhase == .active,
           !model.isStreaming,
           !didRequestStreaming {
            didRequestStreaming = true
            print("实机自动测试：正在启动画面回传")
            model.startStreaming()
            return
        }

        if model.videoIsPlaying,
           !isVideoFullScreen,
           !didRequestFullScreen {
            didRequestFullScreen = true
            print("实机自动测试：正在进入全屏")
            isVideoFullScreen = true
        }
    }
}

extension View {
    func physicalSmokeTest(
        model: PadConnectionModel,
        isVideoFullScreen: Binding<Bool>
    ) -> some View {
        modifier(
            PhysicalSmokeTestModifier(
                model: model,
                isVideoFullScreen: isVideoFullScreen
            )
        )
    }
}
