import SwiftUI
import YingchuiProtocol

/// 与系统键盘共享底部安全区域，不创建模态页面。
struct RemoteKeyboardDock: View {
    @ObservedObject var model: PadConnectionModel
    @ObservedObject var state: RemoteKeyboardState
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                key("Esc", .escape)
                key("Tab", .tab)
                key("删除", .deleteBackward)
                key("回车", .returnKey)
                Divider()
                key("全选", .letterA, modifiers: [.command])
                key("复制", .letterC, modifiers: [.command])
                key("粘贴", .letterV, modifiers: [.command])
                key("剪切", .letterX, modifiers: [.command])
                key("撤销", .letterZ, modifiers: [.command])
                Divider()
                Toggle("密码输入", isOn: $state.secure)
            } label: {
                Image(systemName: state.secure ? "lock" : "command")
            }
            .buttonStyle(.yingchuiPlain)
            .accessibilityLabel("键盘选项")

            RemoteTypingInput(state: state, systemKeyboard: true, onText: model.sendKeyboardText, onKey: model.sendKeyPress)
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(.background, in: RoundedRectangle(cornerRadius: 12))

            Button {
                onClose()
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
            }
            .buttonStyle(.yingchuiPlain)
            .accessibilityLabel("收起键盘")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private func key(
        _ title: String,
        _ key: RemoteKey,
        modifiers: [RemoteKeyModifier] = []
    ) -> some View {
        Button(title) { model.sendKeyPress(key, modifiers: modifiers) }
            .disabled(!model.isPaired)
    }
}
