import XCTest
import YingchuiProtocol
@testable import YingchuiMac

@MainActor
final class AccountLinkTests: XCTestCase {
    func testBothDirectionsCreateIndependentSessionsAndNeverSendLongTermTokens() async throws {
        for donorMac in [true, false] {
            let pair = LinkTestPair(donorMac: donorMac)
            defer { pair.cleanup() }
            pair.start()
            try await pump(pair) { pair.mac.user != nil && pair.pad.user != nil }
            XCTAssertEqual(pair.mac.user?.id, pair.pad.user?.id)
            XCTAssertNotEqual(pair.macStore.record?.session.sessionID, pair.padStore.record?.session.sessionID)
            XCTAssertNotEqual(pair.macStore.record?.session.refreshToken, pair.padStore.record?.session.refreshToken)
            XCTAssertEqual(pair.server.issued, 1)
            XCTAssertEqual(pair.server.exchanges, 1)
            for payload in pair.history {
                let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
                XCTAssertFalse(json.contains("refresh-"))
                XCTAssertFalse(json.contains("access-"))
            }
        }
    }

    func testDifferentExistingAccountsAreNotOverwritten() async throws {
        let pair = LinkTestPair(bothLoggedIn: true)
        defer { pair.cleanup() }
        let other = AccountUser(id: "other-user", nickname: "其他账号", email: "other@example.com")
        pair.padService.confirmedUser = other
        pair.padStore.record = AccountRecord(session: pair.server.session(pair.padService.client, user: other))
        pair.start()
        try await pump(pair) { pair.mac.user != nil && pair.pad.user != nil }
        for _ in 0..<30 { await pair.step() }
        XCTAssertEqual(pair.pad.user?.id, other.id)
        XCTAssertEqual(pair.server.issued, 0)
    }

    func testUnavailableBackendDoesNotAttemptLink() async throws {
        let pair = LinkTestPair()
        defer { pair.cleanup() }
        pair.padService.available = false
        pair.start()
        try await pump(pair) { !pair.mac.isBusy && !pair.pad.isBusy }
        for _ in 0..<30 { await pair.step() }
        XCTAssertNil(pair.pad.user)
        XCTAssertEqual(pair.server.issued, 0)
    }

    func testDisconnectInvalidatesLateExchangeResponse() async throws {
        let pair = LinkTestPair()
        defer { pair.cleanup() }
        pair.server.deferExchange = true
        pair.start()
        try await pump(pair) { pair.server.continuation != nil }
        pair.padLease.invalidate() // 模拟网络队列立即撤销，主线程尚未处理 detach。
        pair.server.continuation?.resume()
        try await pump(pair) { !pair.pad.isBusy }
        XCTAssertNil(pair.padStore.record)
        XCTAssertNil(pair.pad.user)
    }

    func testSignoutDefeatsLateExchangeAndPersistsSuppression() async throws {
        let pair = LinkTestPair()
        defer { pair.cleanup() }
        pair.server.deferExchange = true
        pair.start()
        try await pump(pair) { pair.server.continuation != nil }
        pair.pad.signOut()
        pair.server.continuation?.resume()
        for _ in 0..<50 { await pair.step() }
        XCTAssertNil(pair.padStore.record)
        XCTAssertNil(pair.pad.user)
        XCTAssertTrue(pair.preferences.bool(forKey: AccountModel.linkSuppressedKey))
        XCTAssertFalse(pair.pad.canReceiveAccount)
        XCTAssertFalse(pair.macPreferences.bool(forKey: AccountModel.linkSuppressedKey))
        XCTAssertNotNil(pair.mac.user)
    }

    func testManualLoginWinsOverLateAutomaticLogin() async throws {
        let pair = LinkTestPair()
        defer { pair.cleanup() }
        pair.server.deferExchange = true
        pair.start()
        try await pump(pair) { pair.server.continuation != nil }
        pair.pad.email = "link@example.com"
        pair.pad.code = "123456"
        pair.pad.login()
        try await pump(pair) { pair.pad.user != nil }
        let manuallyAccepted = pair.padStore.record
        pair.server.continuation?.resume()
        for _ in 0..<30 { await pair.step() }
        XCTAssertEqual(pair.padStore.record, manuallyAccepted)
        XCTAssertFalse(pair.pad.isBusy)
    }

    func testDuplicateGrantAndRequestDoNotCreateMoreSessions() async throws {
        let pair = LinkTestPair()
        defer { pair.cleanup() }
        pair.start()
        try await pump(pair) { pair.pad.user != nil }
        let request = try XCTUnwrap(pair.history.first { $0.phase == .request })
        let grant = try XCTUnwrap(pair.history.first { $0.phase == .grant })
        for _ in 0..<10 {
            pair.mac.accountLink.receive(request, from: pair.macLease)
            pair.pad.accountLink.receive(grant, from: pair.padLease)
            await pair.step()
        }
        XCTAssertEqual(pair.server.issued, 1)
        XCTAssertEqual(pair.server.exchanges, 1)
    }

    func testUnattachedAndRevokedPeersCannotAuthorize() async throws {
        let pair = LinkTestPair()
        defer { pair.cleanup() }
        pair.mac.restoreOnce()
        try await pump(pair) { pair.mac.user != nil }
        let unknown = AccountLinkLease()
        let request = AccountLinkMessage(phase: .request, userID: pair.server.user.id,
            clientID: pair.padService.client, challenge: try AccountLinkProof().challenge)
        pair.mac.accountLink.receive(request, from: unknown)
        unknown.invalidate()
        pair.mac.accountLink.attach(unknown, clientID: pair.padService.client) { _ in XCTFail("已撤销通道不能发送账号消息") }
        for _ in 0..<20 { await pair.step() }
        XCTAssertEqual(pair.server.issued, 0)
    }

    func testWireValidationRejectsUnexpectedFieldsAndInvalidProof() throws {
        XCTAssertFalse(AccountLinkMessage(phase: .request, userID: "user", clientID: "other", challenge: String(repeating: "a", count: 43)).isValid)
        XCTAssertFalse(AccountLinkMessage(phase: .request, userID: "user", clientID: "com.yingchui.interconnect.pad", challenge: String(repeating: "/", count: 43)).isValid)
        XCTAssertFalse(AccountLinkMessage(phase: .state, userID: "user", acceptsLogin: true, clientID: "com.yingchui.interconnect.mac").isValid)
        let proof = try AccountLinkProof()
        XCTAssertEqual(proof.verifier.count, 43)
        XCTAssertTrue(AccountLinkMessage.isChallenge(proof.challenge))
        let message = WireMessage(kind: .accountLink, accountLink: .init(phase: .result))
        var decoder = WireMessageDecoder()
        XCTAssertEqual(try decoder.append(WireCodec.encode(message)), [message])
    }

    private func pump(_ pair: LinkTestPair, until condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            await pair.step()
            if condition() { return }
        }
        XCTFail("账号联动没有完成预期状态变化")
        throw AccountError.invalidResponse
    }
}
