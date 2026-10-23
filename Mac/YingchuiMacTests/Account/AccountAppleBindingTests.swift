import XCTest
@testable import YingchuiMac

@MainActor
final class AccountAppleBindingTests: XCTestCase {
    private var configuration: AccountConfiguration {
        .init(baseURL: URL(string: "https://chongyang.asia")!, clientID: AccountConfiguration.defaultClientID,
              contractVersion: "auth-v1.0.0")
    }
    private var challenge: AppleAccountChallenge {
        .init(id: "bind-challenge", requestNonce: "unit-binding-nonce", expiresAt: Date().addingTimeInterval(300))
    }
    private var credential: AppleAccountCredential {
        .init(userID: "apple-test-subject", identityToken: "unit-apple-token", authorizationCode: "unit-apple-code",
              givenName: nil, familyName: nil)
    }
    private var original: AccountUser {
        var user = accountTestSession().user
        user.vip = true
        return user
    }
    private var bound: AccountUser {
        var user = original
        user.identities = ["email", "apple"]
        return user
    }

    func testChallengeUsesAuthenticatedBindingRoute() async throws {
        let transport = AccountTransportDouble(json: #"{"challenge_id":"bind-challenge","nonce":"unit-binding-nonce","expires_in":300}"#)
        let service = try AccountHTTPService(configuration: configuration, transport: transport)
        let result = try await service.appleBindingChallenge(accessToken: "unit-access")
        XCTAssertEqual(result.requestNonce, "unit-binding-nonce")
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/api/auth/v1/apple/bind/challenge")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-access")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client-ID"), AccountConfiguration.defaultClientID)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: XCTUnwrap(request.httpBody)), [:])
    }

    func testBindingReturnsProfileWithoutCreatingSession() async throws {
        let transport = AccountTransportDouble(json: #"{"user_id":"test-user","nickname":"","email":"unit@example.com","identities":["email","apple"],"legacy_profile_ids":[],"vip":true}"#)
        let service = try AccountHTTPService(configuration: configuration, transport: transport)
        let result = try await service.bindApple(accessToken: "unit-access", challenge: challenge, credential: credential)
        XCTAssertEqual(result, bound)
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/api/auth/v1/apple/bind")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-access")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client-ID"), AccountConfiguration.defaultClientID)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: XCTUnwrap(request.httpBody)), [
            "challenge_id": "bind-challenge", "identity_token": "unit-apple-token", "authorization_code": "unit-apple-code"
        ])
    }

    func testBindingAvailabilityIsIndependentFromLoginAndDefaultsClosed() async throws {
        for (field, expected) in [("", false), (",\"apple_binding_available\":false", false), (",\"apple_binding_available\":true", true)] {
            let transport = AccountTransportDouble(json: "{\"version\":\"auth-v1.0.0\",\"email_available\":true,\"apple_available\":true\(field)}")
            let status = try await AccountHTTPService(configuration: configuration, transport: transport).status()
            XCTAssertEqual(status.appleBindingAvailable, expected)
            XCTAssertFalse(status.appleAvailable)
        }
    }

    func testInvalidChallengeLifetimeAndNonceFailClosed() async throws {
        for (nonce, expiry) in [("unit-binding-nonce", 0), ("unit-binding-nonce", 301), ("", 300)] {
            let transport = AccountTransportDouble(json: "{\"challenge_id\":\"test\",\"nonce\":\"\(nonce)\",\"expires_in\":\(expiry)}")
            let service = try AccountHTTPService(configuration: configuration, transport: transport)
            do { _ = try await service.appleBindingChallenge(accessToken: "unit-access"); XCTFail("无效挑战必须拒绝") }
            catch { XCTAssertEqual(error as? AccountError, .invalidResponse) }
        }
        let transport = AccountTransportDouble(json: "{}")
        let service = try AccountHTTPService(configuration: configuration, transport: transport)
        let expired = AppleAccountChallenge(id: "test", requestNonce: "unit-binding-nonce", expiresAt: .distantPast)
        do { _ = try await service.bindApple(accessToken: "unit-access", challenge: expired, credential: credential); XCTFail("不得提交过期授权") }
        catch { XCTAssertEqual(error as? AccountError, .expired) }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testBindingErrorsHaveSafeSpecificMessages() async throws {
        for (status, code, expected) in [
            (409, "apple_identity_conflict", "此 Apple 账户已绑定其他账号。"),
            (503, "apple_binding_unavailable", "Apple 账户绑定尚未开放。"),
            (401, "invalid_apple_binding_challenge", "Apple 绑定授权已失效，请重新授权。"),
            (401, "invalid_apple_credential", "Apple 绑定授权已失效，请重新授权。")
        ] {
            let transport = AccountTransportDouble(status: status, json: "{\"error\":{\"code\":\"\(code)\",\"message\":\"private server details\"}}")
            let service = try AccountHTTPService(configuration: configuration, transport: transport)
            do { _ = try await service.bindApple(accessToken: "unit-access", challenge: challenge, credential: credential); XCTFail("错误不得成为绑定成功") }
            catch { XCTAssertEqual(accountErrorMessage(error), expected) }
        }
    }

    func testBindingCannotChangeUserEmailVIPOrLoseIdentity() throws {
        try bound.validateAppleBinding(to: original)
        var noVIP = bound; noVIP.vip = false
        var noApple = bound; noApple.identities = ["email"]
        var noEmail = bound; noEmail.identities = ["apple"]
        let other = AccountUser(id: "another-user", nickname: "", email: original.email, identities: bound.identities, vip: true)
        let changedEmail = AccountUser(id: original.id, nickname: "", email: "other@example.com", identities: bound.identities, vip: true)
        for invalid in [noVIP, noApple, noEmail, other, changedEmail] {
            XCTAssertThrowsError(try invalid.validateAppleBinding(to: original))
        }
    }

    func testConfirmedBindingPreservesTokensAndEmailSessionAndRefreshesOtherDevice() async throws {
        let service = AccountServiceDouble()
        service.confirmedUser = original
        let store = AccountMemoryStore()
        let sessions = AccountSessionController(service: service, store: store)
        try await sessions.accept(accountTestSession(), expected: sessions.generation)
        let saved = store.record
        let writes = store.saves
        service.confirmedUser = bound
        try await sessions.refreshProfile(expected: sessions.generation, boundTo: original)
        XCTAssertEqual(sessions.user, bound)
        XCTAssertEqual(store.record, saved)
        XCTAssertEqual(store.saves, writes)
        XCTAssertNil(store.record?.session.appleUserID)
        let secondDevice = AccountSessionController(service: service, store: AccountMemoryStore(saved))
        try await secondDevice.restore()
        XCTAssertEqual(secondDevice.user?.identities, ["email", "apple"])
        XCTAssertEqual(secondDevice.user?.vip, true)
    }

    func testLateBindingConfirmationCannotRestoreLoggedOutUser() async throws {
        let service = AccountServiceDouble()
        service.confirmedUser = original
        let store = AccountMemoryStore()
        let sessions = AccountSessionController(service: service, store: store)
        try await sessions.accept(accountTestSession(), expected: sessions.generation)
        service.deferUser = true
        let expected = sessions.generation
        let task = Task { try await sessions.refreshProfile(expected: expected, boundTo: original) }
        for _ in 0..<100 { if service.userContinuation != nil { break }; await Task.yield() }
        let continuation = try XCTUnwrap(service.userContinuation)
        try await sessions.signOut()
        continuation.resume(returning: bound)
        do { try await task.value; XCTFail("退出后不得接收旧绑定结果") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(sessions.user)
        XCTAssertNil(store.record)
    }
}
