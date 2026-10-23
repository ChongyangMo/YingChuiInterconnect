import SwiftUI
import YingchuiProtocol

struct FloatingRemoteKeyboard: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject var model: PadConnectionModel
    @ObservedObject var state: RemoteKeyboardState
    let onSystemKeyboard: () -> Void
    let onClose: () -> Void
    @State private var uppercase = false
    @State private var symbols = false
    @State private var location: CGPoint?
    @GestureState private var drag = CGSize.zero

    var body: some View {
        GeometryReader { geometry in
            let width = min(476.0, geometry.size.width - 16)
            let size = CGSize(width: width, height: 290)
            let initial = location ?? CGPoint(x: geometry.size.width - width / 2 - 16,
                                               y: geometry.size.height - size.height / 2 - 16)
            let center = FloatingKeyboardPlacement.clamp(
                CGPoint(x: initial.x + drag.width, y: initial.y + drag.height),
                panel: size, container: geometry.size
            )
            keyboard(width: width, origin: initial, container: geometry.size, panel: size)
                .frame(width: width, height: size.height)
                .background {
                    if reduceTransparency {
                        RoundedRectangle(cornerRadius: 20).fill(Color(white: 0.12))
                    } else {
                        RoundedRectangle(cornerRadius: 20).fill(.ultraThinMaterial)
                            .overlay(RoundedRectangle(cornerRadius: 20).fill(.black.opacity(0.28)))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
                .position(center)
                .onChange(of: geometry.size) { _, newSize in
                    location = FloatingKeyboardPlacement.clamp(center, panel: size, container: newSize)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("悬浮键盘")
        }
        .coordinateSpace(name: "remoteKeyboardCanvas")
        .onChange(of: state.lastPressedKey) { _, code in
            if let code {
                if (4...29).contains(code) { symbols = false }
                else if (45...56).contains(code), ![52, 54, 55].contains(code) { symbols = true }
            }
        }
    }

    private func keyboard(width: CGFloat, origin: CGPoint, container: CGSize, panel: CGSize) -> some View {
        let keyWidth = (width - 34) / 10
        return VStack(spacing: 2) {
            HStack(spacing: 2) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 8)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(coordinateSpace: .named("remoteKeyboardCanvas"))
                        .updating($drag) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            location = FloatingKeyboardPlacement.clamp(
                                CGPoint(x: origin.x + value.translation.width, y: origin.y + value.translation.height),
                                panel: panel, container: container
                            )
                        })
                    .accessibilityLabel("拖动键盘")
                Spacer(minLength: 0)
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(RemoteKeyboardKeyStyle()).accessibilityLabel("收起键盘")
            }
            RemoteKeyboardNumberRow(state: state, keyWidth: keyWidth, send: model.sendFloatingKeyboardText)
                .disabled(model.keyboardLanguageChanging || !model.isPaired)
            row(symbols ? "[]{}<>\\|~`" : "qwertyuiop", keyWidth: keyWidth)
            row(symbols ? "-/:;()$&@" : "asdfghjkl", keyWidth: keyWidth)
            HStack(spacing: 2) {
                Button { uppercase.toggle() } label: {
                    Image(systemName: uppercase ? "shift.fill" : "shift")
                }
                .buttonStyle(RemoteKeyboardKeyStyle(hardwarePressed: state.shiftHeld || uppercase)).accessibilityLabel("切换大小写")
                row(symbols ? ".,?!'\"#" : "zxcvbnm", keyWidth: keyWidth)
                Button {
                    model.sendKeyPress(.deleteBackward)
                } label: { Image(systemName: "delete.left") }
                .buttonStyle(RemoteKeyboardKeyStyle(hardwarePressed: state.pressedKeys.contains(42))).accessibilityLabel("删除")
            }
            HStack(spacing: 2) {
                Button(symbols ? "ABC" : "#+=") { symbols.toggle() }.buttonStyle(RemoteKeyboardKeyStyle())
                    .accessibilityLabel(symbols ? "切换到字母" : "切换到符号")
                Button(model.remoteKeyboardLanguage == .pinyin ? "中" : "英", action: model.toggleKeyboardLanguage)
                    .buttonStyle(RemoteKeyboardKeyStyle(hardwarePressed: model.remoteKeyboardLanguage == .pinyin))
                    .disabled(model.keyboardLanguageChanging || !model.isPaired)
                    .accessibilityLabel(model.remoteKeyboardLanguage == .pinyin ? "切换到英文" : "切换到 Mac 简体拼音")
                shortcuts
                Button { model.sendKeyPress(.space) } label: {
                    Text("空格").frame(maxWidth: .infinity)
                }.buttonStyle(RemoteKeyboardKeyStyle(hardwarePressed: state.pressedKeys.contains(44)))
                RemoteKeyboardPunctuationKeys(state: state, isPinyin: model.remoteKeyboardLanguage == .pinyin,
                                              send: model.sendFloatingKeyboardText)
                    .disabled(model.keyboardLanguageChanging || !model.isPaired)
                Button { model.sendKeyPress(.returnKey) } label: { Image(systemName: "return") }
                    .buttonStyle(RemoteKeyboardKeyStyle(hardwarePressed: state.pressedKeys.contains(40))).accessibilityLabel("远程回车")
            }
        }
        .padding(8)
        .tint(.white)
    }

    private func row(_ characters: String, keyWidth: CGFloat) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(characters), id: \.self) { character in
                let letter = (uppercase || (state.shiftHeld != state.capsLock)) && !symbols ? String(character).uppercased() : String(character)
                Button(letter) { model.sendFloatingKeyboardText(letter) }
                    .buttonStyle(RemoteKeyboardKeyStyle(hardwarePressed: RemoteKeyboardHID.code(for: character).map { state.pressedKeys.contains($0) } ?? false))
                    .frame(width: keyWidth, height: 44)
                    .disabled(model.keyboardLanguageChanging || !model.isPaired)
            }
        }
    }

    private var shortcuts: some View {
        Menu {
            Button("iPad 输入法", systemImage: "keyboard", action: onSystemKeyboard)
            Divider()
            key("Esc", .escape)
            key("Tab", .tab)
            key("全选", .letterA, modifiers: [.command])
            key("复制", .letterC, modifiers: [.command])
            key("粘贴", .letterV, modifiers: [.command])
            key("剪切", .letterX, modifiers: [.command])
            key("撤销", .letterZ, modifiers: [.command])
            Divider()
            Toggle("密码输入", isOn: $state.secure)
        } label: { Image(systemName: "command") }
        .buttonStyle(RemoteKeyboardKeyStyle(hardwarePressed: state.pressedKeys.contains(227) || state.pressedKeys.contains(231))).accessibilityLabel("键盘选项")
    }

    private func key(_ title: String, _ key: RemoteKey, modifiers: [RemoteKeyModifier] = []) -> some View {
        Button(title) { model.sendKeyPress(key, modifiers: modifiers) }.disabled(!model.isPaired)
    }

}

enum FloatingKeyboardPlacement {
    static func clamp(_ center: CGPoint, panel: CGSize, container: CGSize) -> CGPoint {
        CGPoint(x: min(max(center.x, panel.width / 2 + 8), max(panel.width / 2 + 8, container.width - panel.width / 2 - 8)),
                y: min(max(center.y, panel.height / 2 + 8), max(panel.height / 2 + 8, container.height - panel.height / 2 - 8)))
    }
}
