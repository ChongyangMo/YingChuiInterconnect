import XCTest
@testable import YingchuiPad

@MainActor
final class AccountVIPTests: XCTestCase {
    private var configuration: AccountConfiguration {
        .init(baseURL: URL(string: "https://chongyang.asia")!,
              clientID: AccountConfiguration.defaultClientID, contractVersion: "auth-v1.0.0")
    }

    func testVIPComesFromBooleanServerFieldAndMissingRemainsUnknown() async throws {
        let cases: [(String, Bool?)] = [("true", true), ("false", false), ("null", nil), ("", nil)]
        for (field, expected) in cases {
            let extra = field.isEmpty ? "" : ",\"vip\":\(field)"
            let transport = AccountTransportDouble(json: userJSON(extra))
            let service = try AccountHTTPService(configuration: configuration, transport: transport)
            let user = try await service.currentUser(accessToken: "unit-access")
            XCTAssertEqual(user.vip, expected)
        }
    }

    func testStringAndNumericVIPAreRejected() async throws {
        for value in ["\"true\"", "\"false\"", "1", "0", "{}"] {
            let transport = AccountTransportDouble(json: userJSON(",\"vip\":\(value)"))
            let service = try AccountHTTPService(configuration: configuration, transport: transport)
            do { _ = try await service.currentUser(accessToken: "unit-access"); XCTFail("VIP 必须是布尔字段") }
            catch { XCTAssertEqual(error as? AccountError, .invalidResponse) }
        }
    }

    func testOldKeychainUserDoesNotAcquireVIPDuringDecode() throws {
        let old = Data(#"{"id":"test-user","nickname":"","email":"unit@example.com","identities":["email"]}"#.utf8)
        let user = try JSONDecoder().decode(AccountUser.self, from: old)
        XCTAssertNil(user.vip)
        var vip = user
        vip.vip = true
        XCTAssertEqual(try JSONDecoder().decode(AccountUser.self, from: JSONEncoder().encode(vip)).vip, true)
    }

    func testStoredVIPIsNotPublishedBeforeServerConfirmationAndLogoutClearsIt() async throws {
        let base = accountTestSession()
        var cached = base.user
        cached.vip = true
        let stored = AccountSession(user: cached, sessionID: base.sessionID,
            accessToken: base.accessToken, refreshToken: base.refreshToken,
            accessExpiresAt: base.accessExpiresAt, refreshExpiresAt: base.refreshExpiresAt, appleUserID: nil)
        let service = AccountServiceDouble()
        var current = base.user
        current.vip = false
        service.confirmedUser = current
        let controller = AccountSessionController(service: service, store: AccountMemoryStore(AccountRecord(session: stored)))
        XCTAssertNil(controller.user)
        try await controller.restore()
        XCTAssertEqual(controller.user?.vip, false)
        try await controller.signOut()
        XCTAssertNil(controller.user)
    }

    func testLoginUsesConfirmedVIPInsteadOfOlderLoginResponse() async throws {
        let service = AccountServiceDouble()
        var confirmed = accountTestSession().user
        confirmed.vip = true
        service.confirmedUser = confirmed
        let controller = AccountSessionController(service: service, store: AccountMemoryStore())
        try await controller.accept(accountTestSession(), expected: controller.generation)
        XCTAssertEqual(controller.user?.vip, true)
    }

    private func userJSON(_ extra: String) -> String {
        "{\"user_id\":\"test-user\",\"nickname\":\"\",\"email\":\"unit@example.com\",\"identities\":[\"email\"],\"legacy_profile_ids\":[]\(extra)}"
    }
}
