#if DEBUG
import SwiftUI
import YingchuiProtocol

/// 坐标由测试时读取的 Mac 菜单位置提供，不在正式界面中启用。
struct CaptureMenuSmokeTest: ViewModifier {
    @ObservedObject var model: PadConnectionModel
    @State private var started = false

    func body(content: Content) -> some View {
        content.task(id: model.videoIsPlaying) {
            let arguments = ProcessInfo.processInfo.arguments
            guard model.videoIsPlaying, !started,
                  let index = arguments.firstIndex(of: "--capture-menu-smoke-test") else { return }
            started = true
            guard arguments.count > index + 2,
                  let x = Double(arguments[index + 1]), let y = Double(arguments[index + 2]),
                  (0...1).contains(x), (0...1).contains(y) else {
                model.eventLog.record("菜单实机测试失败：缺少有效的菜单坐标")
                return
            }
            do {
                try await Task.sleep(for: .seconds(5))
                for attempt in 1...3 {
                    guard let stream = model.activeStreamID else {
                        model.eventLog.record("菜单实机测试失败：视频流已停止")
                        return
                    }
                    model.eventLog.record("菜单实机测试：第 \(attempt) 次远程点击，坐标 \(x)、\(y)")
                    if let mouseIndex = arguments.firstIndex(of: "--capture-menu-mouse") {
                        guard arguments.count > mouseIndex + 2,
                              let width = Double(arguments[mouseIndex + 1]),
                              let height = Double(arguments[mouseIndex + 2]),
                              width.isFinite, height.isFinite, width > 0, height > 0 else {
                            model.eventLog.record("菜单实机测试失败：缺少实际显示器逻辑尺寸")
                            return
                        }
                        model.returnPointerToDisplay()
                        try await Task.sleep(for: .milliseconds(100))
                        model.sendPointerDelta(x: (x - 0.5) * width, y: (y - 0.5) * height)
                        try await Task.sleep(for: .milliseconds(100))
                        model.sendMouseClick(button: .left)
                    } else {
                        model.sendTouch(.init(phase: .tap, x: x, y: y), streamID: stream)
                    }
                    try await observeFrames(for: 5, stream: stream)
                    model.sendKeyPress(.escape)
                    try await observeFrames(for: 3, stream: stream)
                }
                model.eventLog.record("菜单实机测试：三次远程点击完成")
            } catch {
                model.eventLog.record("菜单实机测试已终止：\(error.localizedDescription)")
            }
        }
    }

    @MainActor private func observeFrames(for seconds: Double, stream: UUID) async throws {
        let start = ProcessInfo.processInfo.systemUptime
        var lastChange = start
        var maximumGap = 0.0
        let initial = model.playbackStatistics.snapshot().decodedFrames
        var previous = initial
        while ProcessInfo.processInfo.systemUptime - start < seconds {
            try await Task.sleep(for: .milliseconds(10))
            guard model.activeStreamID == stream else {
                throw ObservationError.streamChanged
            }
            let now = ProcessInfo.processInfo.systemUptime
            let frames = model.playbackStatistics.snapshot().decodedFrames
            maximumGap = max(maximumGap, now - lastChange)
            if frames != previous { lastChange = now; previous = frames }
        }
        model.eventLog.record("菜单实机测试：观察 \(seconds) 秒，解码新增 \(previous - initial) 帧，最大无新帧间隔 \(Int(maximumGap * 1000)) 毫秒")
        guard maximumGap < 1 else { throw ObservationError.frameGap(Int(maximumGap * 1000)) }
    }

    private enum ObservationError: LocalizedError {
        case streamChanged, frameGap(Int)
        var errorDescription: String? {
            switch self {
            case .streamChanged: "测试期间视频流发生重建"
            case .frameGap(let milliseconds): "画面连续性检查失败：无新帧 \(milliseconds) 毫秒"
            }
        }
    }
}
#endif
