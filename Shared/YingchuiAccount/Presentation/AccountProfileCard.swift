import SwiftUI

/// 身份信息直接排在页面上，不再套大卡片。
struct AccountProfileCard: View {
    let user: AccountUser
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
        layout {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 40, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { identity }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 6) { identity }
                }
                if !user.nickname.isEmpty, let email = user.email {
                    Text(email).font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    @ViewBuilder private var identity: some View {
        Text(user.displayName).font(.headline)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        if user.vip == true { AccountVIPBadge() }
    }
}
