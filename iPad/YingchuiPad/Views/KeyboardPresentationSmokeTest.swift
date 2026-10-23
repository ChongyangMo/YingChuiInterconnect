import SwiftUI
import GameController

struct KeyboardPresentationSmokeTest: ViewModifier {
    @ObservedObject var model: PadConnectionModel
    @Binding var isPresented: Bool
    @State private var hasRun = false

    func body(content: Content) -> some View {
        content.task(id: model.videoIsPlaying) {
#if DEBUG
            guard ProcessInfo.processInfo.arguments.contains("--keyboard-smoke-test"),
                  model.videoIsPlaying, !hasRun else { return }
            do {
                try await Task.sleep(for: .seconds(2))
                try Task.checkCancellation()
                hasRun = true
                print("键盘实机测试：实体键盘\(GCKeyboard.coalesced == nil ? "未连接" : "已连接")")
                for index in 1...3 {
                    print("键盘实机测试：第 \(index) 次打开，已解码 \(model.videoFramesDecoded) 帧")
                    isPresented = true
                    if index <= 2, ProcessInfo.processInfo.arguments.contains("--pinyin-smoke-test") {
                        model.toggleKeyboardLanguage()
                    }
                    try await Task.sleep(for: .seconds(4))
                    isPresented = false
                    print("键盘实机测试：第 \(index) 次关闭，回传 \(model.isStreaming)，已解码 \(model.videoFramesDecoded) 帧")
                    try await Task.sleep(for: .seconds(3))
                }
                print("键盘实机测试：三次打开关闭已完成")
            } catch { print("键盘实机测试：测试被中断：\(error.localizedDescription)") }
#endif
        }
    }
}
