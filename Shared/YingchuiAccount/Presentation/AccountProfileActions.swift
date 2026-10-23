import SwiftUI

struct AccountProfileActions: View {
    @ObservedObject var account: AccountModel
    let user: AccountUser

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) {
                    appleBinding.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    signOut.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 4) {
                    appleBinding
                    signOut
                }
            }
        }
    }

    @ViewBuilder private var appleBinding: some View {
        if user.identities.contains("email") {
            if user.identities.contains("apple") {
                Label("已绑定 Apple", systemImage: "applelogo")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(minHeight: actionHeight)
                    .accessibilityIdentifier("account-apple-bound")
            } else {
                AppleAccountButton(title: "绑定 Apple", compact: true) { account.bindApple(window: $0) }
                    .frame(minHeight: actionHeight)
                    .disabled(account.isBusy)
            }
        }
    }

    private var signOut: some View {
        Button("退出登录", role: .destructive) { account.signOut() }
            .font(.callout)
            .buttonStyle(.yingchuiPlain)
            .frame(minHeight: actionHeight)
            .accessibilityIdentifier("account-sign-out")
            .disabled(account.isBusy)
    }

    private var actionHeight: CGFloat {
#if os(iOS)
        44
#else
        28
#endif
    }
}
