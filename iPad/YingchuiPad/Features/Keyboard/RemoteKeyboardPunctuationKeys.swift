import SwiftUI

struct RemoteKeyboardPunctuationKeys: View {
    @ObservedObject var state: RemoteKeyboardState
    let isPinyin: Bool
    let send: (String) -> Void

    var body: some View {
        Group {
            key(isPinyin ? "，" : ",", input: ",", code: 54, label: "逗号")
            key(isPinyin ? "。" : ".", input: ".", code: 55, label: "句号")
            key(isPinyin ? "“”" : "\"", input: "\"", code: 52, label: "双引号")
                .contextMenu {
                    Button("单引号") { send("'") }
                    Button("双引号") { send("\"") }
                }
                .accessibilityHint("长按选择单引号或双引号")
                .accessibilityAction(named: Text("输入单引号")) { send("'") }
        }
    }

    private func key(_ title: String, input: String, code: Int, label: String) -> some View {
        // 拼音模式继续发送对应实体按键，由 Mac 输入法处理候选词及中文标点。
        Button(title) { send(input) }
            .buttonStyle(RemoteKeyboardKeyStyle(hardwarePressed: state.pressedKeys.contains(code)))
            .accessibilityLabel(label)
    }
}
