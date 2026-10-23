#if DEBUG
import SwiftUI
import YingchuiProtocol

/// 仅由明确的实机调试启动参数启用，不进入发布版本。
struct CursorSmokeTest: ViewModifier {
    @ObservedObject var model: PadConnectionModel
    @State private var started = false

    func body(content: Content) -> some View {
        content.task(id: model.videoIsPlaying) {
            guard ProcessInfo.processInfo.arguments.contains("--cursor-smoke-test"),
                  model.videoIsPlaying, !started else { return }
            started = true
            do {
                try await Task.sleep(for: .milliseconds(500))
                let cursor = model.videoRenderer.cursor
                guard let stream = cursor.streamID, let original = cursor.position else {
                    throw ProbeError.failed("独立光标没有协商成功")
                }
                let beforeFrames = model.playbackStatistics.snapshot().decodedFrames
                // 不点击其他应用；只连续往返移动，结束后等待真实系统确认。
                for index in 0..<60 {
                    guard model.activeStreamID == stream else { throw ProbeError.failed("探测期间回传流改变") }
                    model.sendPointerDelta(x: index.isMultiple(of: 2) ? 3 : -3, y: 0)
                    try await Task.sleep(for: .milliseconds(17))
                }
                let deadline = Date().addingTimeInterval(3)
                while cursor.hasUnconfirmedInput, Date() < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard !cursor.hasUnconfirmedInput, let final = cursor.position,
                      abs(final.x - original.x) < 2, abs(final.y - original.y) < 2 else {
                    throw ProbeError.failed("光标没有收到系统确认或往返位置不一致")
                }
                let frames = model.playbackStatistics.snapshot().decodedFrames - beforeFrames
                model.eventLog.record("独立光标实机验证通过：60 次移动已收到系统确认，往返误差小于 2 逻辑点，期间解码 \(frames) 帧")
            } catch {
                model.eventLog.record("独立光标实机验证失败：\(error.localizedDescription)")
            }
        }
    }

    private enum ProbeError: LocalizedError {
        case failed(String)
        var errorDescription: String? { switch self { case .failed(let text): return text } }
    }
}
#endif
