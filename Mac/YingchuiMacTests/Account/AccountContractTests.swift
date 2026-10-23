import XCTest
@testable import YingchuiMac

@MainActor
final class AccountContractTests: XCTestCase {
    private let configuration = AccountConfiguration(baseURL: URL(string: "https://chongyang.asia")!,
        clientID: "com.yingchui.interconnect.mac", contractVersion: "auth-v1.0.0")

    func testContractUsesExactCodePathAndPurpose() async throws {
        let transport = AccountTransportDouble(json: #"{"expires_in":300,"retry_after":60}"#)
        let service = try AccountHTTPService(configuration: configuration, transport: transport)
        let receipt = try await service.sendEmailCode(email: "unit@example.com")
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://chongyang.asia/api/auth/v1/email/code")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(body, ["email": "unit@example.com", "purpose": "login"])
        XCTAssertEqual(receipt.email, "unit@example.com")
        XCTAssertGreaterThan(receipt.expiresAt, Date())
    }

    func testEmptyNicknameIsValidAndUsesVerifiedEmail() async throws {
        let transport = AccountTransportDouble(json: #"{"user_id":"test-user","nickname":"","avatar_url":"","email":"unit@example.com","identities":["email"],"legacy_profile_ids":[]}"#)
        let service = try AccountHTTPService(configuration: configuration, transport: transport)
        let user = try await service.currentUser(accessToken: "unit-access")
        XCTAssertEqual(user.displayName, "unit@example.com")
        let requests = await transport.requests
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer unit-access")
        XCTAssertNil(requests.first?.url?.query)
    }

    func testMalformedSuccessAndLegacyTokenAreRejected() async throws {
        for json in [#"{"token":"unit@example.com"}"#, #"{"token_type":"Bearer","access_token":"unit@example.com","refresh_token":"unit-refresh","expires_in":900,"refresh_expires_in":2592000,"session_id":"test-session","is_new_user":false,"user":{"user_id":"test-user","nickname":"","email":"unit@example.com","identities":["email"],"legacy_profile_ids":[]}}"#] {
            let service = try AccountHTTPService(configuration: configuration, transport: AccountTransportDouble(json: json))
            do { _ = try await service.login(email: "unit@example.com", code: "123456"); XCTFail("旧凭据或缺失数据必须拒绝") }
            catch { XCTAssertEqual(error as? AccountError, .invalidResponse) }
        }
    }

    func testRateLimitRequiresMatchingHeaderAndBody() async throws {
        let json = #"{"error":{"code":"rate_limited","message":"limit","retry_after":60}}"#
        let transport = AccountTransportDouble(status: 429, json: json, headers: ["Retry-After":"60"])
        let service = try AccountHTTPService(configuration: configuration, transport: transport)
        do { _ = try await service.sendEmailCode(email: "unit@example.com"); XCTFail("应报告限流") }
        catch AccountError.rateLimited(let date) { XCTAssertGreaterThan(date.timeIntervalSinceNow, 50) }
        let invalid = try AccountHTTPService(configuration: configuration,
            transport: AccountTransportDouble(status: 429, json: json, headers: ["Retry-After":"10"]))
        do { _ = try await invalid.sendEmailCode(email: "unit@example.com"); XCTFail("矛盾限流应报错") }
        catch { XCTAssertEqual(error as? AccountError, .invalidResponse) }
    }

    func testUndeployedStatusIsNotLoginAvailability() async throws {
        let service = try AccountHTTPService(configuration: configuration,
            transport: AccountTransportDouble(status: 404, json: #"{"error":"接口不存在"}"#))
        do { _ = try await service.status(); XCTFail("未部署不得标为可用") }
        catch { XCTAssertEqual(error as? AccountError, .unavailable("登录服务尚未部署。")) }
    }

    func testUnexpectedVersionAndRedirectAreRejected() async throws {
        let service = try AccountHTTPService(configuration: configuration,
            transport: AccountTransportDouble(json: #"{"version":"unknown","email_available":true,"apple_available":false}"#))
        do { _ = try await service.status(); XCTFail("契约版本必须匹配") }
        catch { XCTAssertEqual(error as? AccountError, .invalidResponse) }
        let redirect = try AccountHTTPService(configuration: configuration,
            transport: AccountTransportDouble(status: 302, json: ""))
        do { _ = try await redirect.currentUser(accessToken: "unit-access"); XCTFail("不应接受重定向") }
        catch { XCTAssertEqual(error as? AccountError, .invalidResponse) }
    }

    func testSecureConfigurationIsRequired() {
        for url in ["http://chongyang.asia", "https://localhost", "https://chongyang.asia?token=example", "https://other.example"] {
            XCTAssertThrowsError(try AccountConfiguration(baseURL: URL(string: url)!,
                clientID: configuration.clientID, contractVersion: configuration.contractVersion).validate())
        }
    }

    func testAppleIsDisabledWithoutAnyNetworkRequest() async throws {
        let transport = AccountTransportDouble(json: "{}")
        let service = try AccountHTTPService(configuration: configuration, transport: transport)
        do { _ = try await service.appleChallenge(); XCTFail("默认不应启用Apple") }
        catch { XCTAssertEqual(error as? AccountError, .unavailable("Apple 登录尚未开放。")) }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testPreparedAppleChallengePreservesServerNonce() async throws {
        let transport = AccountTransportDouble(json: #"{"challenge_id":"unit-challenge","nonce":"unit-server-nonce","expires_in":300}"#)
        let enabled = AccountConfiguration(baseURL: configuration.baseURL, clientID: configuration.clientID,
                                           contractVersion: configuration.contractVersion, appleEnabled: true)
        let service = try AccountHTTPService(configuration: enabled, transport: transport)
        let challenge = try await service.appleChallenge()
        XCTAssertEqual(challenge.requestNonce, "unit-server-nonce")
        let requests = await transport.requests
        XCTAssertEqual(requests.first?.url?.path, "/api/auth/v1/apple/challenge")
        XCTAssertEqual(requests.first?.httpMethod, "POST")
    }

    func testAppleManagedUserMayHaveNoEmail() async throws {
        let transport = AccountTransportDouble(json: #"{"user_id":"unit-apple-user","nickname":"","email":null,"identities":["apple"],"legacy_profile_ids":[]}"#)
        let service = try AccountHTTPService(configuration: configuration, transport: transport)
        let user = try await service.currentUser(accessToken: "unit-access")
        XCTAssertEqual(user.id, "unit-apple-user")
        XCTAssertNil(user.email)
        XCTAssertEqual(user.identities, ["apple"])
    }

    func testRealKeychainLifecycleUsesIsolatedService() async throws {
        let store = AccountKeychainStore(service: "com.yingchui.interconnect.mac.account.unittest.\(UUID().uuidString)")
        let loaded1 = try await store.load()
        XCTAssertNil(loaded1)
        let first = AccountRecord(session: accountTestSession())
        try await store.save(first)
        let loaded2 = try await store.load()
        XCTAssertEqual(loaded2, first)
        let pending = AccountRecord(session: first.session, pendingRevocation: true)
        try await store.save(pending)
        let loaded3 = try await store.load()
        XCTAssertEqual(loaded3, pending)
        try await store.remove()
        let loaded4 = try await store.load()
        XCTAssertNil(loaded4)
    }
}
