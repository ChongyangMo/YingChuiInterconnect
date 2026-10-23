#if DEBUG
import SwiftUI
import YingchuiProtocol

struct VideoInvestigationSmokeTest: ViewModifier {
    @ObservedObject var model: PadConnectionModel

    func body(content: Content) -> some View {
        content.task {
            guard ProcessInfo.processInfo.arguments.contains("--video-reconfiguration-test") else { return }
            let original = model.selectedQuality
            defer {
                if model.isInBackgroundState.value { model.resumeAfterForeground() }
                model.selectQuality(original)
            }
            do {
                try await waitUntil { model.videoIsPlaying }
                try await Task.sleep(for: .seconds(2))
                guard let other = model.resolutionOptions.first(where: {
                    model.resolutionText(for: $0) != model.resolutionText(for: original)
                }) else { throw ProbeError.failed("没有另一档实际分辨率") }
                for quality in [other, original] {
                    let previous = model.activeStreamID
                    let before = model.playbackStatistics.snapshot().decodedFrames
                    model.selectQuality(quality)
                    try await waitUntil {
                        model.activeStreamID != previous && model.videoIsPlaying && !model.displayModeChanging
                            && model.playbackStatistics.snapshot().decodedFrames > before
                    }
                    model.eventLog.record("分辨率实机验证通过：\(model.videoResolutionText)，已继续实际解码")
                    try await Task.sleep(for: .seconds(2))
                }
                // 调用真实生命周期清理与恢复代码；此项不冒充实际按键锁屏。
                let oldEpoch = model.connectionEpoch.value
                model.prepareForBackground()
                try await Task.sleep(for: .seconds(1))
                guard !model.isConnected, model.wantsStreaming else {
                    throw ProbeError.failed("后台清理没有保留恢复意图")
                }
                model.resumeAfterForeground()
                try await waitUntil {
                    model.connectionEpoch.value != oldEpoch && model.isPaired && model.videoIsPlaying
                }
                model.eventLog.record("前后台生命周期实机组件验证通过：清理连接后重新配对并恢复实际解码；尚需真实锁屏验证")
            } catch {
                model.eventLog.record("视频重配置验证失败：\(error.localizedDescription)")
            }
        }
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ProbeError.failed("等待实际解码或重配置超时")
    }

    private enum ProbeError: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let detail) = self { return detail }; return nil }
    }
}
#endif
