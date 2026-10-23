import SwiftUI

/// 说明内容固定，不随实时统计刷新而重新创建浮层。
struct PadSettingsInfoButton<Label: View>: View {
    let topic: PadSettingsTopic
    @ViewBuilder var label: () -> Label
    @State private var presentedTopic: PadSettingsTopic?

    var body: some View {
        Button { presentedTopic = topic } label: { label().contentShape(Rectangle()) }
            .buttonStyle(.yingchuiRow)
            .accessibilityHint("显示用途说明")
            .popover(item: $presentedTopic) { topic in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(topic.title).font(.headline)
                        Text(topic.explanation).font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
                .frame(idealWidth: 300, maxWidth: 340, idealHeight: 230, maxHeight: 360)
                .presentationCompactAdaptation(.popover)
            }
    }
}

struct PadSettingsHelpLabel: View {
    let topic: PadSettingsTopic
    var iconOnly = false

    var body: some View {
        PadSettingsInfoButton(topic: topic) {
            HStack(spacing: 6) {
                if !iconOnly { Text(topic.title).multilineTextAlignment(.leading) }
                Image(systemName: "info.circle")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(minWidth: 44, minHeight: 44, alignment: iconOnly ? .center : .leading)
        }
        .accessibilityLabel("了解\(topic.title)")
    }
}
