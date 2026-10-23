import SwiftUI

/// 中英文共用数字行；原生长按菜单负责区分数字点击和符号选择，避免重复发送。
struct RemoteKeyboardNumberRow: View {
    @ObservedObject var state: RemoteKeyboardState
    let keyWidth: CGFloat
    let send: (String) -> Void

    private let keys: [(digit: String, symbol: String)] = [
        ("1", "!"), ("2", "@"), ("3", "#"), ("4", "$"), ("5", "%"),
        ("6", "^"), ("7", "&"), ("8", "*"), ("9", "("), ("0", ")")
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(keys, id: \.digit) { key in
                Button { send(key.digit) } label: {
                    Text(key.digit)
                        .frame(width: keyWidth - 8, height: 44)
                        .overlay(alignment: .topTrailing) {
                            Text(key.symbol)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.8))
                                .padding(.top, 3)
                        }
                }
                .buttonStyle(RemoteKeyboardKeyStyle(hardwarePressed:
                    RemoteKeyboardHID.code(for: Character(key.digit)).map { state.pressedKeys.contains($0) } ?? false))
                .frame(width: keyWidth, height: 44)
                .accessibilityLabel(key.digit)
                .accessibilityHint("长按输入 \(key.symbol)")
                .contextMenu {
                    Button(key.symbol) { send(key.symbol) }
                }
                .accessibilityAction(named: Text("输入 \(key.symbol)")) { send(key.symbol) }
            }
        }
    }
}
