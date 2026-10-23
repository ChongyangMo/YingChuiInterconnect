import SwiftUI

/// 只在服务端确认当前登录用户具有 VIP 资格时显示。
struct AccountVIPBadge: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text("VIP")
            .font(.caption.weight(.bold))
            .tracking(0.6)
            .foregroundStyle(scheme == .dark ? Color.yellow : Color(red: 0.43, green: 0.27, blue: 0.03))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.yellow.opacity(scheme == .dark ? 0.16 : 0.23),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .fixedSize()
            .accessibilityLabel("VIP 用户")
            .accessibilityIdentifier("account-vip-badge")
    }
}
