import SwiftUI

struct AccountLoginForm: View {
    @ObservedObject var account: AccountModel
    @FocusState private var focus: Field?
    @ScaledMetric(relativeTo: .body) private var codeRowMinimumWidth = 290
    @State private var formWidth: CGFloat = 352
    private enum Field { case email, code }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 0) {
                inputRow(focused: focus == .email) {
                    TextField("", text: $account.email)
                        .textContentType(.emailAddress)
#if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
#endif
                        .textFieldStyle(.plain)
                        .overlay(alignment: .leading) { placeholder("邮箱", when: account.email.isEmpty) }
                        .accessibilityLabel("邮箱")
                        .accessibilityIdentifier("account-email")
                        .focused($focus, equals: .email)
                        .onSubmit {
                            if canSendCode { account.sendCode() }
                            else { focus = .code }
                        }
                }
                Divider().padding(.horizontal, 16).accessibilityHidden(true)
                inputRow(focused: focus == .code) {
                    let layout = formWidth >= codeRowMinimumWidth
                        ? AnyLayout(HStackLayout(spacing: 8))
                        : AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                    layout { codeField; sendCode }
                }
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.primary.opacity(0.18), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            if let receipt = account.codeReceipt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(receipt.expiresAt > context.date ? "验证码已发送" : "验证码已过期，请重新发送")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button { submitLogin() } label: {
                Text(account.emailActivity == .signingIn ? "正在登录…" : "登录")
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.yingchuiPrimary)
            .accessibilityIdentifier("account-email-login")
            .disabled(!canLogin)
        }
        .disabled(account.isBusy && !account.isChecking)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { formWidth = $0 }
        .onChange(of: account.email) { account.emailChanged() }
        .onChange(of: account.codeReceipt?.expiresAt) { _, expiry in
            if expiry != nil { focus = .code }
        }
    }

    private var hasEmail: Bool { !account.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canSendCode: Bool {
        !account.isBusy && account.availabilityMessage == nil && hasEmail && Date() >= account.resendAt
    }
    private var canLogin: Bool {
        !account.isBusy && account.availabilityMessage == nil && hasEmail && !account.code.isEmpty
    }
    private func submitLogin() {
        guard canLogin else { return }
        account.login()
    }

    private var codeField: some View {
        TextField("", text: $account.code)
            .textContentType(.oneTimeCode)
#if os(iOS)
            .keyboardType(.numberPad)
#endif
            .textFieldStyle(.plain)
            .overlay(alignment: .leading) { placeholder("验证码", when: account.code.isEmpty) }
            .frame(minWidth: 80, minHeight: 44)
            .accessibilityLabel("验证码")
            .accessibilityIdentifier("account-code")
            .focused($focus, equals: .code)
            .onSubmit { submitLogin() }
    }

    private var sendCode: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(ceil(account.resendAt.timeIntervalSince(context.date))))
            Button(account.emailActivity == .sendingCode ? "正在发送…" : (seconds > 0 ? "\(seconds) 秒后重发" : "获取验证码")) {
                account.sendCode()
            }
            .font(.callout)
            .monospacedDigit()
            .fixedSize(horizontal: true, vertical: false)
            .buttonStyle(.yingchuiPlain)
            .frame(minHeight: 44)
            .accessibilityIdentifier("account-send-code")
            .disabled(account.isBusy || account.availabilityMessage != nil || seconds > 0 || !hasEmail)
        }
    }

    private func inputRow<Content: View>(focused: Bool, @ViewBuilder content: () -> Content) -> some View {
        content().font(.body)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .padding(.horizontal, 16)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(focused ? Color.accentColor : .clear, lineWidth: 2)
                    .padding(2).allowsHitTesting(false)
            }
    }

    @ViewBuilder private func placeholder(_ title: String, when visible: Bool) -> some View {
        if visible {
            // 系统输入框的占位文字会再次降低透明度，独立绘制以保持双端明暗模式的可读性。
            Text(title).foregroundStyle(.secondary)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}
