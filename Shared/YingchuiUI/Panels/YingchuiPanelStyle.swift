import SwiftUI

/// 设置与账户共用的中性色层级，跟随系统明暗与对比度。
enum YingchuiPanelPalette {
    static func page(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.055, green: 0.059, blue: 0.067) : Color(red: 0.965, green: 0.969, blue: 0.977)
    }
    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.092, green: 0.098, blue: 0.111) : .white
    }
    static func inset(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.045) : Color.black.opacity(0.035)
    }
    static func line(_ scheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        Color.primary.opacity(contrast == .increased ? 0.45 : (scheme == .dark ? 0.10 : 0.07))
    }
}

struct YingchuiPanelBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View { YingchuiPanelPalette.page(scheme).ignoresSafeArea() }
}

struct YingchuiPanel<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        VStack(spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(YingchuiPanelPalette.surface(scheme), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(YingchuiPanelPalette.line(scheme, contrast: contrast), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

struct YingchuiPanelIcon: View {
    let systemName: String
    var tint: Color = .primary
    var size: CGFloat = 40
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.46, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(YingchuiPanelPalette.inset(scheme), in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct YingchuiPanelDivider: View {
    var inset: CGFloat = 68
    var body: some View { Divider().padding(.leading, inset).padding(.trailing, 16).accessibilityHidden(true) }
}

struct YingchuiPanelRowLabel: View {
    let title: String
    let systemName: String
    var tint: Color = .primary
    var showsChevron = false
    var body: some View {
        HStack(spacing: 12) {
            YingchuiPanelIcon(systemName: systemName, tint: tint)
            Text(title).font(.body.weight(.medium)).foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}
