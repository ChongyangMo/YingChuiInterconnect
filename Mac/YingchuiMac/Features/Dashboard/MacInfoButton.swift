import SwiftUI

struct MacCardInfo: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// 打开时固定说明内容，避免回传统计刷新干扰正在阅读的浮层。
struct MacInfoButton<Label: View>: View {
    let title: String
    var information: () -> MacCardInfo
    @ViewBuilder var label: () -> Label
    @State private var presentedInfo: MacCardInfo?
    @State private var isHovering = false

    var body: some View {
        Button { presentedInfo = information() } label: {
            label().contentShape(Rectangle())
        }
        .buttonStyle(.yingchuiRow)
        .background(Color.accentColor.opacity(isHovering ? 0.06 : 0),
                    in: RoundedRectangle(cornerRadius: 10))
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
        .accessibilityHint("显示用途说明")
        .help("了解\(title)")
        .popover(item: $presentedInfo, arrowEdge: .bottom) { info in
            VStack(alignment: .leading, spacing: 8) {
                Text(info.title).font(.headline)
                Text(info.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(16)
            .frame(width: 300, alignment: .leading)
        }
    }
}
