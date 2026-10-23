#if os(macOS)
import AppKit
#else
import UIKit
#endif
import AuthenticationServices
import Combine
import Foundation

@MainActor
final class AccountModel: ObservableObject {
    enum EmailActivity { case sendingCode, signingIn }
    @Published var email = ""
    @Published var code = ""
    @Published var isBusy = false
    @Published private(set) var isChecking = false
    @Published private(set) var emailActivity: EmailActivity?
    @Published var message: String?
    @Published private(set) var codeReceipt: EmailCodeReceipt?
    @Published private(set) var resendAt = Date.distantPast
    let sessions: AccountSessionController
    @Published private(set) var availabilityMessage: String?
    @Published private(set) var appleAvailable = false
    let service: any AccountService
    let apple = AppleAccountAuthorization()
    private var operation: Task<Void, Never>?
    private var observation: AnyCancellable?
    private var operationID = UUID()
    private var didRestore = false
    var linkRestoreFinished = false
    var linkAvailable = false
    var appleBindingAvailable = false
    var needsProfileRefresh = false
    let linkPreferences: UserDefaults
    lazy var accountLink = AccountLinkCoordinator(account: self)
    private var lastStatusCheck = Date.distantPast

    func prepareForPresentation(now: Date = Date()) {
        guard !isBusy else { return }
        if !didRestore { restoreOnce() }
        else if user != nil || needsProfileRefresh { refreshAccountProfile() }
        else if now.timeIntervalSince(lastStatusCheck) >= 60 { checkAvailability() }
    }

    private func checkAvailability() {
        run(checking: true) { try await self.updateAvailability() }
    }

    func updateAvailability() async throws {
        let status = try await service.status()
        try Task.checkCancellation()
        availabilityMessage = status.emailAvailable ? nil : "邮箱登录尚未开放。"
        appleAvailable = status.appleAvailable
        appleBindingAvailable = status.appleBindingAvailable
        linkAvailable = status.deviceLinkAvailable
        lastStatusCheck = Date()
    }

    init(service: (any AccountService)? = nil, store: any AccountSessionStore = AccountKeychainStore(),
         preferences: UserDefaults = .standard) {
        let resolved = service ?? makeAccountService()
        self.service = resolved
        linkPreferences = preferences
        availabilityMessage = resolved.availabilityMessage ?? "正在检查登录服务。"
        sessions = AccountSessionController(service: resolved, store: store)
        observation = sessions.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
            Task { @MainActor [weak self] in self?.accountLink.accountChanged() }
        }
    }

    var user: AccountUser? { sessions.user }
    var hasStoredSession: Bool { sessions.hasStoredSession }

    func restoreOnce() {
        guard !didRestore else { return }
        didRestore = true
        restore()
    }

    func restore() {
        run(checking: true) {
            try await self.sessions.restore()
            self.needsProfileRefresh = false
            self.linkRestoreFinished = true
            try await self.updateAvailability()
        }
    }

    func sendCode() {
        run(emailActivity: .sendingCode) {
            let email = try self.validatedEmail()
            guard Date() >= self.resendAt else { throw AccountError.rateLimited(self.resendAt) }
            let receipt = try await self.service.sendEmailCode(email: email)
            try Task.checkCancellation()
            guard !receipt.email.isEmpty, receipt.expiresAt > Date(), receipt.resendAt > Date() else {
                throw AccountError.invalidResponse
            }
            self.codeReceipt = receipt
            self.resendAt = receipt.resendAt
            self.code = ""
        }
    }

    func login() {
        cancelLinkedLoginForManualAction()
        run(emailActivity: .signingIn) {
            let email = try self.validatedEmail()
            let code = self.code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard code.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else { throw AccountError.missingCode }
            if let receipt = self.codeReceipt, receipt.expiresAt <= Date() { throw AccountError.expired }
            let expected = self.sessions.generation
            let session: AccountSession
            do { session = try await self.service.login(email: email, code: code) }
            catch {
                self.code = ""
                self.codeReceipt = nil
                throw error
            }
            try await self.sessions.accept(session, expected: expected)
            self.linkRestoreFinished = true
            self.linkPreferences.set(false, forKey: Self.linkSuppressedKey)
            self.clearInputs()
        }
    }

    func loginWithApple(window: ASPresentationAnchor?) {
        cancelLinkedLoginForManualAction()
        run {
            guard let window else { throw AccountError.appleAuthorizationFailed }
            // 先检查已签名能力；无能力时不启动系统授权弹窗。
            try AppleAccountAuthorization.requireCapability()
            let expected = self.sessions.generation
            let challenge = try await self.service.appleChallenge()
            try self.sessions.check(expected)
            let credential = try await self.apple.authorize(challenge: challenge, window: window)
            try self.sessions.check(expected)
            let session = try await self.service.exchangeApple(challenge: challenge, credential: credential)
            guard session.appleUserID == credential.userID else { throw AccountError.invalidResponse }
            try await self.sessions.accept(session, expected: expected)
            self.linkRestoreFinished = true
            self.linkPreferences.set(false, forKey: Self.linkSuppressedKey)
            self.clearInputs()
        }
    }

    func signOut() {
        linkPreferences.set(true, forKey: Self.linkSuppressedKey)
        cancel()
        run { try await self.sessions.signOut() }
    }

    func cancel() {
        accountLink.cancelPending()
        operationID = UUID()
        operation?.cancel()
        operation = nil
        apple.cancel()
        sessions.invalidateRequests()
        isBusy = false
        isChecking = false
        emailActivity = nil
    }

    func close() {
        cancel()
        code = ""
    }

    func emailChanged() {
        code = ""
        codeReceipt = nil
    }

    private func clearInputs() {
        code = ""
        email = ""
        codeReceipt = nil
    }

    private func validatedEmail() throws -> String {
        let value = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard value.utf8.count <= 254, value.utf8.allSatisfy({ (33...126).contains($0) }),
              !value.contains("<"), !value.contains(">"),
              parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              !value.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw AccountError.invalidEmail }
        // auth-v1.0.0 明确要求 trim、小写及单一 ASCII 邮箱。
        return value
    }

    func run(checking: Bool = false, emailActivity: EmailActivity? = nil,
             _ action: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        message = nil
        isBusy = true
        isChecking = checking
        self.emailActivity = emailActivity
        let id = UUID()
        operationID = id
        operation = Task {
            defer {
                if self.operationID == id {
                    self.isBusy = false
                    self.isChecking = false
                    self.emailActivity = nil
                    self.operation = nil
                    self.accountLink.accountChanged()
                }
            }
            do {
                try await action()
            } catch is CancellationError {
                // 用户主动取消是终止操作，不进行重试或继续提交。
            } catch {
                guard self.operationID == id else { return }
                if case AccountError.rateLimited(let until) = error { self.resendAt = until }
                self.message = accountErrorMessage(error)
            }
        }
    }
}
