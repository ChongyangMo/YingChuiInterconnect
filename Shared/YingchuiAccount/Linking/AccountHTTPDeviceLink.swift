import Foundation
import YingchuiProtocol

extension AccountHTTPService {
    func createDeviceLink(accessToken: String, recipientClientID: String, challenge: String) async throws -> AccountDeviceGrant {
        let started = Date()
        guard AccountLinkCoordinator.clientIDs.contains(recipientClientID), AccountLinkMessage.isChallenge(challenge) else {
            throw AccountError.invalidResponse
        }
        let response: DeviceGrantResponse = try await json("device-link/grants", body: [
            "recipient_client_id": recipientClientID, "code_challenge": challenge, "code_challenge_method": "S256"
        ], accessToken: accessToken)
        guard (32...512).contains(response.grant_token.utf8.count), !response.user_id.isEmpty, response.user_id.utf8.count <= 256,
              (1...60).contains(response.expires_in) else { throw AccountError.invalidResponse }
        return AccountDeviceGrant(token: response.grant_token, userID: response.user_id,
                                  expiresAt: started.addingTimeInterval(Double(response.expires_in)))
    }

    func exchangeDeviceLink(grant: String, verifier: String) async throws -> AccountSession {
        guard (32...512).contains(grant.utf8.count), AccountLinkMessage.isChallenge(verifier) else {
            throw AccountError.invalidResponse
        }
        let started = Date()
        let response: SessionResponse = try await json("device-link/exchange", body: [
            "grant_token": grant, "code_verifier": verifier
        ])
        return try response.session(started: started)
    }
}

private struct DeviceGrantResponse: Decodable {
    let grant_token: String
    let expires_in: Int
    let user_id: String
}
