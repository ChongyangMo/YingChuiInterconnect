import XCTest
@testable import YingchuiMac

@MainActor
final class AccountLinkContractTests: XCTestCase {
    private var config: AccountConfiguration {
        .init(baseURL: URL(string: "https://chongyang.asia")!, clientID: AccountConfiguration.defaultClientID,
              contractVersion: "auth-v1.0.0")
    }

    func testGrantRequestBindsRecipientAndProofWithBearerOnlyInHeader() async throws {
        let transport = AccountTransportDouble(json: #"{"grant_token":"01234567890123456789012345678901","expires_in":60,"user_id":"linked-user"}"#)
        let service = try AccountHTTPService(configuration: config, transport: transport)
        let proof = try AccountLinkProof()
        _ = try await service.createDeviceLink(accessToken: "source-access", recipientClientID: "com.yingchui.interconnect.pad", challenge: proof.challenge)
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/api/auth/v1/device-link/grants")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer source-access")
        let body = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(body, ["recipient_client_id": "com.yingchui.interconnect.pad", "code_challenge": proof.challenge, "code_challenge_method": "S256"])
        XCTAssertFalse(String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self).contains(proof.verifier))
    }

    func testExchangeUsesLocalClientAndReturnsIndependentSession() async throws {
        let transport = AccountTransportDouble(json: #"{"token_type":"Bearer","access_token":"recipient-access","refresh_token":"recipient-refresh","expires_in":900,"refresh_expires_in":2592000,"session_id":"recipient-session","is_new_user":false,"user":{"user_id":"linked-user","nickname":"","email":"unit@example.com","identities":["email"],"legacy_profile_ids":[]}}"#)
        let service = try AccountHTTPService(configuration: config, transport: transport)
        let proof = try AccountLinkProof()
        let session = try await service.exchangeDeviceLink(grant: String(repeating: "a", count: 32), verifier: proof.verifier)
        XCTAssertEqual(session.sessionID, "recipient-session")
        XCTAssertNil(session.appleUserID)
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/api/auth/v1/device-link/exchange")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client-ID"), config.clientID)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.url?.query)
    }

    func testOlderBackendDoesNotAdvertiseLinkAndExplicitCapabilityDoes() async throws {
        for available in [false, true] {
            let extra = available ? ",\"device_link_available\":true" : ""
            let transport = AccountTransportDouble(json: "{\"version\":\"auth-v1.0.0\",\"email_available\":true,\"apple_available\":false\(extra)}")
            let status = try await AccountHTTPService(configuration: config, transport: transport).status()
            XCTAssertEqual(status.deviceLinkAvailable, available)
        }
    }

    func testInvalidGrantFailsWithoutReturningServerSecrets() async throws {
        let transport = AccountTransportDouble(status: 401, json: #"{"error":{"code":"invalid_device_link_grant","message":"secret-grant-detail"}}"#)
        let service = try AccountHTTPService(configuration: config, transport: transport)
        do {
            _ = try await service.exchangeDeviceLink(grant: String(repeating: "a", count: 32), verifier: try AccountLinkProof().verifier)
            XCTFail("无效授权不能继续登录")
        } catch { XCTAssertFalse(accountErrorMessage(error).contains("secret")) }
    }
}
