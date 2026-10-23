import SwiftUI

/// 双端共用按压反馈；只改变绘制，不改变按钮布局或动作触发时机。
struct YingchuiButtonStyle: ButtonStyle {
    enum Emphasis { case primary, secondary, plain, row }
    var emphasis: Emphasis = .secondary
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && isEnabled
        let tint: Color = configuration.role == .destructive ? .red : .accentColor
        let filled = emphasis == .primary
        let unbordered = emphasis == .plain || emphasis == .row
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        configuration.label
            .fontWeight(emphasis == .row ? .regular : .semibold)
            .padding(.horizontal, emphasis == .row ? 0 : 12)
            .padding(.vertical, 4)
            .frame(minWidth: minimumHeight, minHeight: minimumHeight)
            .foregroundStyle(filled ? Color.white : (emphasis == .row ? Color.primary : tint))
            .brightness(filled || emphasis == .row ? 0 : (colorScheme == .dark ? 0.08 : -0.16))
            .background {
                shape.fill(filled ? tint : tint.opacity(unbordered ? 0 : 0.1))
                    .brightness(filled ? -0.08 : 0)
            }
            .overlay {
                shape.fill((filled ? Color.black : tint).opacity(pressed ? 0.16 : 0))
                    .allowsHitTesting(false)
            }
            .overlay {
                if !unbordered && !filled {
                    shape.strokeBorder(tint.opacity(contrast == .increased ? 0.7 : 0.22), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: filled && isEnabled ? tint.opacity(pressed ? 0.06 : 0.18) : .clear,
                    radius: pressed ? 1 : 4, y: pressed ? 0 : 2)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(reduceMotion || !pressed ? 1 : (emphasis == .row ? 0.985 : 0.96))
            .animation(reduceMotion ? nil : (pressed ? .easeOut(duration: 0.09) : .spring(duration: 0.26, bounce: 0.18)), value: pressed)
            .contentShape(.interaction, shape)
    }

    private var minimumHeight: CGFloat {
#if os(iOS)
        44
#else
        28
#endif
    }

    private var cornerRadius: CGFloat {
#if os(iOS)
        12
#else
        8
#endif
    }
}

extension ButtonStyle where Self == YingchuiButtonStyle {
    static var yingchuiPrimary: Self { Self(emphasis: .primary) }
    static var yingchuiSecondary: Self { Self(emphasis: .secondary) }
    static var yingchuiPlain: Self { Self(emphasis: .plain) }
    static var yingchuiRow: Self { Self(emphasis: .row) }
}
