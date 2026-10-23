import XCTest
@testable import YingchuiPad

@MainActor
final class AccountSessionTests: XCTestCase {
    func testRestoreRequiresConfirmedIdentity() async throws {
        let saved = accountTestSession()
        let store = AccountMemoryStore(AccountRecord(session: saved))
        let service = AccountServiceDouble()
        service.confirmedUser = AccountUser(id: "different-user", nickname: "", email: "unit@example.com")
        let controller = AccountSessionController(service: service, store: store)
        do { try await controller.restore(); XCTFail("应拒绝身份不一致") }
        catch { XCTAssertEqual(error as? AccountError, .invalidResponse) }
        XCTAssertNil(controller.user)
    }

    func testLateLoginCannotRestoreAfterCancellation() async throws {
        let session = accountTestSession()
        let service = AccountServiceDouble()
        service.deferUser = true
        let store = AccountMemoryStore()
        let controller = AccountSessionController(service: service, store: store)
        let expected = controller.generation
        let login = Task { try await controller.accept(session, expected: expected) }
        try await waitUntil { service.userContinuation != nil }
        controller.invalidateRequests()
        service.userContinuation?.resume(returning: session.user)
        do { try await login.value; XCTFail("迟到请求不得提交") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(store.record)
        XCTAssertNil(controller.user)
    }

    func testConcurrentRefreshIsSingleAndLogoutDefeatsLateResponse() async throws {
        let session = accountTestSession(accessExpiry: Date().addingTimeInterval(-1))
        let service = AccountServiceDouble()
        service.confirmedUser = session.user
        let store = AccountMemoryStore(AccountRecord(session: session))
        let controller = AccountSessionController(service: service, store: store)
        let restore = Task { try await controller.restore() }
        try await waitUntil { service.refreshContinuation != nil }
        let second = Task { try await controller.accessToken() }
        await Task.yield()
        XCTAssertEqual(service.refreshCalls, 1)
        try await controller.signOut()
        service.refreshContinuation?.resume(returning: accountTestSession(suffix: "rotated"))
        do { try await restore.value; XCTFail("退出后的恢复应取消") } catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await second.value; XCTFail("退出后的刷新应取消") } catch {
            XCTAssertTrue(error is CancellationError || error as? AccountError == .unauthorized)
        }
        XCTAssertNil(store.record)
        XCTAssertNil(controller.user)
        XCTAssertEqual(service.revokeCalls, 1)
    }

    func testRefreshTimeoutPersistsRevocationAndNeverReplays() async throws {
        let session = accountTestSession(accessExpiry: Date().addingTimeInterval(-1))
        let service = AccountServiceDouble()
        let store = AccountMemoryStore(AccountRecord(session: session))
        let controller = AccountSessionController(service: service, store: store)
        let restore = Task { try await controller.restore() }
        try await waitUntil { service.refreshContinuation != nil }
        service.refreshContinuation?.resume(throwing: URLError(.timedOut))
        do { try await restore.value; XCTFail("刷新超时应终止") }
        catch { XCTAssertEqual(error as? AccountError, .refreshUncertain) }
        XCTAssertEqual(store.record?.pendingRevocation, true)
        do { _ = try await controller.accessToken(); XCTFail("禁止再次刷新") }
        catch { XCTAssertEqual(error as? AccountError, .unauthorized) }
        let restarted = AccountSessionController(service: service, store: store)
        try await restarted.restore()
        XCTAssertEqual(service.refreshCalls, 1)
        XCTAssertEqual(service.revokeCalls, 1)
        XCTAssertNil(restarted.user)
        XCTAssertNil(store.record)
    }

    func testLogoutNetworkFailureCannotRestoreOnRestart() async throws {
        let session = accountTestSession()
        let store = AccountMemoryStore(AccountRecord(session: session))
        let service = AccountServiceDouble()
        service.confirmedUser = session.user
        let controller = AccountSessionController(service: service, store: store)
        try await controller.restore()
        service.revokeFailure = URLError(.notConnectedToInternet)
        do { try await controller.signOut(); XCTFail("退出失败应报告") } catch { XCTAssertTrue(error is URLError) }
        XCTAssertNil(controller.user)
        XCTAssertEqual(store.record?.pendingRevocation, true)
        let restarted = AccountSessionController(service: service, store: store)
        do { try await restarted.restore(); XCTFail("离线撤销应报告") } catch { XCTAssertTrue(error is URLError) }
        XCTAssertNil(restarted.user)
        service.revokeFailure = nil
        try await restarted.signOut()
        XCTAssertNil(store.record)
    }

    func testExpiredRefreshIsRemovedWithoutAuthenticating() async throws {
        let old = accountTestSession()
        let session = AccountSession(user: old.user, sessionID: old.sessionID, accessToken: old.accessToken,
            refreshToken: old.refreshToken, accessExpiresAt: Date().addingTimeInterval(-100),
            refreshExpiresAt: Date().addingTimeInterval(-1), appleUserID: nil)
        let store = AccountMemoryStore(AccountRecord(session: session))
        let service = AccountServiceDouble()
        let controller = AccountSessionController(service: service, store: store)
        do { try await controller.restore(); XCTFail("到期会话应失败") }
        catch { XCTAssertEqual(error as? AccountError, .expired) }
        XCTAssertNil(store.record)
        XCTAssertNil(controller.user)
        XCTAssertEqual(service.refreshCalls, 0)
    }

    func testKeychainWriteFailureNeverReportsLoginSuccess() async throws {
        let session = accountTestSession()
        let service = AccountServiceDouble()
        service.confirmedUser = session.user
        let store = AccountMemoryStore()
        store.failure = .keychain(-25293)
        let controller = AccountSessionController(service: service, store: store)
        do { try await controller.accept(session, expected: controller.generation); XCTFail("存储失败必须报错") }
        catch { XCTAssertEqual(error as? AccountError, .keychain(-25293)) }
        XCTAssertNil(controller.user)
    }

    func testRefreshSubmissionPersistsIntentBeforeResponse() async throws {
        let session = accountTestSession(accessExpiry: Date().addingTimeInterval(-1))
        let service = AccountServiceDouble()
        let store = AccountMemoryStore(AccountRecord(session: session))
        let controller = AccountSessionController(service: service, store: store)
        let restore = Task { try await controller.restore() }
        try await waitUntil { service.refreshContinuation != nil }
        XCTAssertEqual(store.record?.pendingRevocation, true)
        controller.invalidateRequests()
        service.refreshContinuation?.resume(throwing: CancellationError())
        do { try await restore.value; XCTFail("取消必须终止刷新") } catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await controller.accessToken(); XCTFail("禁止重放已取消的刷新") }
        catch { XCTAssertEqual(error as? AccountError, .unauthorized) }
        let restarted = AccountSessionController(service: service, store: store)
        try await restarted.restore()
        XCTAssertEqual(service.refreshCalls, 1)
        XCTAssertEqual(service.revokeCalls, 1)
        XCTAssertNil(store.record)
    }

    func testSuccessfulRefreshReplacesPersistentIntentWithRotatedSession() async throws {
        let session = accountTestSession(accessExpiry: Date().addingTimeInterval(-1))
        let service = AccountServiceDouble()
        service.confirmedUser = session.user
        let store = AccountMemoryStore(AccountRecord(session: session))
        let controller = AccountSessionController(service: service, store: store)
        let restore = Task { try await controller.restore() }
        try await waitUntil { service.refreshContinuation != nil }
        let rotated = accountTestSession(suffix: "rotated")
        service.refreshContinuation?.resume(returning: rotated)
        try await restore.value
        XCTAssertEqual(store.record, AccountRecord(session: rotated))
        XCTAssertEqual(controller.user, session.user)
        XCTAssertEqual(service.refreshCalls, 1)
        XCTAssertEqual(store.saves, 2)
    }

    func testConcurrentAcceptCannotReplaceAlreadyCommittedSession() async throws {
        let service = AccountServiceDouble()
        service.deferUser = true
        let store = AccountMemoryStore()
        let controller = AccountSessionController(service: service, store: store)
        let expected = controller.generation
        let first = Task { try await controller.accept(accountTestSession(), expected: expected) }
        try await waitUntil { service.userContinuations.count == 1 }
        let second = Task { try await controller.accept(accountTestSession(suffix: "second"), expected: expected) }
        try await waitUntil { service.userContinuations.count == 2 }
        service.userContinuations[0].resume(returning: accountTestSession().user)
        try await first.value
        service.userContinuations[1].resume(returning: accountTestSession().user)
        do { try await second.value; XCTFail("already accepted") }
        catch { XCTAssertEqual(error as? AccountError, .operationInProgress) }
        XCTAssertEqual(store.record?.session.accessToken, accountTestSession().accessToken)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("测试请求没有进入等待状态")
        throw AccountError.invalidResponse
    }
}
