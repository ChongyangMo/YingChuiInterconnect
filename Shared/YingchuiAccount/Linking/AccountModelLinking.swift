import Foundation

extension AccountModel: AccountLinkAccount {
    static let linkSuppressedKey = "YingchuiAccountAutomaticLoginSuppressed"

    var linkUserID: String? { linkRestoreFinished && linkAvailable ? user?.id : nil }
    var canReceiveAccount: Bool {
        linkRestoreFinished && linkAvailable && !isBusy && !hasStoredSession && user == nil
            && !linkPreferences.bool(forKey: Self.linkSuppressedKey)
    }

    func cancelLinkedLoginForManualAction() {
        if accountLink.pending != nil { cancel() }
    }

    func issueAccountGrant(clientID: String, challenge: String, userID: String) async throws -> AccountDeviceGrant {
        guard linkUserID == userID else { throw AccountError.unauthorized }
        let expected = sessions.generation
        let token = try await sessions.accessToken()
        try sessions.check(expected)
        let grant = try await service.createDeviceLink(accessToken: token, recipientClientID: clientID, challenge: challenge)
        try sessions.check(expected)
        guard linkUserID == userID else { throw CancellationError() }
        return grant
    }

    func receiveAccountGrant(_ token: String, verifier: String, userID: String,
                             authorized: @escaping @MainActor () -> Bool) async throws {
        guard canReceiveAccount, authorized() else { throw CancellationError() }
        let expected = sessions.generation
        isBusy = true
        message = nil
        defer {
            if sessions.generation == expected { isBusy = false }
            accountLink.accountChanged()
        }
        let session = try await service.exchangeDeviceLink(grant: token, verifier: verifier)
        try sessions.check(expected)
        guard authorized() else { throw CancellationError() }
        guard session.user.id == userID, session.appleUserID == nil else { throw AccountError.invalidResponse }
        try await sessions.accept(session, expected: expected, authorized: authorized)
    }

    func accountLinkFailed(_ text: String) { message = text }
}
