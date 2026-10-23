import SwiftUI

/// 保留通用按钮的按压节奏，为中性面板提供黑白主按钮和弱化次按钮。
struct YingchuiPanelButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        let pressed = enabled && configuration.isPressed
        let destructive = configuration.role == .destructive
        let foreground: Color = primary ? (scheme == .dark ? .black : .white) : (destructive ? .red : .primary)
        configuration.label
            .font(.body.weight(.semibold))
            .padding(.horizontal, 18)
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(foreground)
            .background(primary ? Color.primary : YingchuiPanelPalette.inset(scheme), in: Capsule())
            .overlay {
                Capsule().strokeBorder(primary ? Color.clear : YingchuiPanelPalette.line(scheme, contrast: contrast), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay { Capsule().fill(foreground.opacity(pressed ? 0.12 : 0)).allowsHitTesting(false) }
            .opacity(enabled ? 1 : 0.42)
            .scaleEffect(reduceMotion || !pressed ? 1 : 0.98)
            .animation(reduceMotion ? nil : .easeOut(duration: pressed ? 0.09 : 0.18), value: pressed)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == YingchuiPanelButtonStyle {
    static var yingchuiPanelPrimary: Self { Self(primary: true) }
    static var yingchuiPanelSecondary: Self { Self() }
}
