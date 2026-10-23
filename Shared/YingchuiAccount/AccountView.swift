import SwiftUI

struct AccountView: View {
    @ObservedObject var account: AccountModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: account.user == nil ? 24 : 20) {
            HStack(spacing: 12) {
                Text(account.user == nil ? "登录" : "账户")
                    .font(account.user == nil ? .title.weight(.semibold) : .headline)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(.yingchuiPlain)
                    .font(account.user == nil ? .body : .callout)
                    .accessibilityIdentifier("account-cancel")
            }
            if let user = account.user {
                AccountProfileCard(user: user)
                AccountProfileActions(account: account, user: user)
            } else if account.hasStoredSession || account.sessions.needsLogoutRetry {
                recoveryActions
            } else {
                AccountLoginForm(account: account)
            }
            if account.availabilityMessage != nil && !account.isBusy {
                Button("重新检查") { account.restore() }.buttonStyle(.yingchuiPlain)
            }
            if let message = account.message ?? account.availabilityMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("account-message")
            }
            if account.user == nil && !account.hasStoredSession && !account.sessions.needsLogoutRetry {
                AppleAccountButton { account.loginWithApple(window: $0) }
                    .frame(width: 44, height: 44)
                    .disabled(account.isBusy || !account.appleAvailable)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
        }
        .padding(account.user == nil ? 28 : 24)
        .frame(maxWidth: 408)
#if os(macOS)
        .frame(width: 408)
#endif
        .background(.background)
        .onAppear { account.prepareForPresentation() }
        .onDisappear { account.close() }
    }

    private var recoveryActions: some View {
        VStack(spacing: 12) {
            if !account.sessions.needsLogoutRetry {
                Button("重新连接") { account.restore() }
                    .buttonStyle(.yingchuiPanelPrimary).disabled(account.isBusy)
            }
            Button(account.sessions.needsLogoutRetry ? "重试退出" : "退出登录", role: .destructive) {
                account.signOut()
            }.buttonStyle(.yingchuiPanelSecondary).disabled(account.isBusy)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}
