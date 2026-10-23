#if DEBUG
import SwiftUI
import YingchuiProtocol

struct DisplayModeSmokeTest: ViewModifier {
    @ObservedObject var model: PadConnectionModel
    @State private var started = false

    func body(content: Content) -> some View {
        content.task(id: model.videoAspectRatio != nil) {
            guard ProcessInfo.processInfo.arguments.contains("--display-mode-smoke-test"),
                  model.videoAspectRatio != nil, !started else { return }
            do {
                try await Task.sleep(for: .seconds(2))
                try Task.checkCancellation()
                started = true
                let originalMode = model.selectedDisplayMode
                let originalPlacement = model.displayPlacement
                let headless = model.activeDisplayState?.mode == .standalone
                for mode in [RemoteDisplayMode.extended, .mirror, .extended] {
                    let oldStream = model.activeStreamID
                    model.selectDisplayMode(mode)
                    if model.selectedDisplayMode == mode, model.displayModeChanging {
                        try await waitUntil { !model.displayModeChanging && model.activeStreamID != oldStream }
                    }
                    guard model.activeDisplayState?.mode == (headless ? .standalone : mode) else {
                        throw SmokeError.failed("实际模式与硬件状态不符")
                    }
                    let before = model.videoFramesDecoded
                    model.returnPointerToDisplay()
                    try await waitUntil { model.videoFramesDecoded > before }
                    print("显示模式实机测试：请求 \(mode.title)，确认 \(model.displayModeTitle)，解码 \(model.videoFramesDecoded) 帧")
                    try await Task.sleep(for: .seconds(3))
                }
                model.selectDisplayMode(originalMode)
                model.selectDisplayPlacement(originalPlacement)
                try await waitUntil { !model.displayModeChanging }
                print("显示模式实机测试：切换、鼠标返回与画面连续性通过")
            } catch is CancellationError {
                print("显示模式实机测试：生命周期改变，测试已取消")
            } catch {
                print("显示模式实机测试失败：\(error.localizedDescription)")
            }
        }
    }

    @MainActor private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<120 {
            if predicate() { return }
            if !model.isStreaming || !model.isPaired { throw SmokeError.failed(model.streamStatusText) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SmokeError.failed("等待显示配置或画面超时")
    }
    private enum SmokeError: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
    }
}
#endif
