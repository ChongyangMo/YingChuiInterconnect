import SwiftUI

struct PadSettingsControlChoices: View {
    @Binding var mode: PadControlMode
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { choices }
            VStack(spacing: 12) { choices }
        }
        .accessibilityIdentifier("control-mode-picker")
    }

    @ViewBuilder private var choices: some View {
        ForEach(PadControlMode.allCases) { item in
            let selected = mode == item
            Button { mode = item } label: {
                HStack(spacing: 10) {
                    Image(systemName: item == .touch ? "hand.point.up" : "keyboard")
                        .font(.system(size: 21, weight: .regular)).accessibilityHidden(true)
                    Text(item.title).font(.body.weight(.medium)).fixedSize()
                    Spacer(minLength: 8)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17)).accessibilityHidden(true)
                }
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(selected ? Color.accentColor.opacity(scheme == .dark ? 0.13 : 0.055) : YingchuiPanelPalette.inset(scheme),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor.opacity(0.65) : YingchuiPanelPalette.line(scheme, contrast: contrast), lineWidth: 1)
                }
            }
            .buttonStyle(.yingchuiRow)
            .accessibilityLabel(item.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityValue(selected ? "已选中" : "未选中")
        }
    }
}
