import Foundation

extension AccountHTTPService {
    func appleBindingChallenge(accessToken: String) async throws -> AppleAccountChallenge {
        guard !accessToken.isEmpty else { throw AccountError.unauthorized }
        let started = Date()
        let response: AppleBindingChallengeResponse = try await json("apple/bind/challenge", body: [:], accessToken: accessToken)
        guard (1...256).contains(response.challenge_id.utf8.count),
              (16...512).contains(response.nonce.utf8.count), (1...300).contains(response.expires_in) else {
            throw AccountError.invalidResponse
        }
        let expiry = started.addingTimeInterval(Double(response.expires_in))
        guard expiry > Date() else { throw AccountError.expired }
        return AppleAccountChallenge(id: response.challenge_id, requestNonce: response.nonce, expiresAt: expiry)
    }

    func bindApple(accessToken: String, challenge: AppleAccountChallenge, credential: AppleAccountCredential) async throws -> AccountUser {
        guard !accessToken.isEmpty else { throw AccountError.unauthorized }
        guard challenge.expiresAt > Date() else { throw AccountError.expired }
        guard !challenge.id.isEmpty, !credential.userID.isEmpty,
              !credential.identityToken.isEmpty, !credential.authorizationCode.isEmpty else { throw AccountError.invalidResponse }
        let response: UserResponse = try await json("apple/bind", body: [
            "challenge_id": challenge.id, "identity_token": credential.identityToken,
            "authorization_code": credential.authorizationCode
        ], accessToken: accessToken)
        let user = try response.user()
        guard user.identities.contains("apple"), user.identities.contains("email") else { throw AccountError.invalidResponse }
        return user
    }
}

private struct AppleBindingChallengeResponse: Decodable {
    let challenge_id: String
    let nonce: String
    let expires_in: Int
}

extension AccountUser {
    func validateAppleBinding(to previous: AccountUser) throws {
        try validate()
        guard id == previous.id, email == previous.email, vip == previous.vip,
              previous.identities.contains("email"), email?.isEmpty == false,
              identities.contains("email"), identities.contains("apple") else { throw AccountError.invalidResponse }
    }
}
