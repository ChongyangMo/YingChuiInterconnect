import XCTest
@testable import YingchuiMac

@MainActor
final class AccountPresentationTests: XCTestCase {
    func testReopeningAccountDoesNotReloadKeychainOrRepeatFreshStatus() async throws {
        let store = DelayedAccountStore()
        let service = AccountServiceDouble()
        let model = AccountModel(service: service, store: store)
        model.restoreOnce()
        try await waitUntil { !model.isBusy }
        for _ in 0..<4 { model.close(); model.prepareForPresentation() }
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(store.loads, 1)
        XCTAssertEqual(service.statusCalls, 1)
        model.prepareForPresentation(now: Date().addingTimeInterval(61))
        try await waitUntil { !model.isBusy }
        XCTAssertEqual(service.statusCalls, 2)
        XCTAssertEqual(store.loads, 1)
    }

    func testSlowKeychainLoadCanBeCancelledWithoutBlockingUIOrPublishingOldIdentity() async throws {
        let store = DelayedAccountStore()
        store.delayLoad = true
        let service = AccountServiceDouble()
        let model = AccountModel(service: service, store: store)
        model.restoreOnce()
        try await waitUntil { store.loadContinuation != nil }
        XCTAssertTrue(model.isBusy)
        model.close()
        XCTAssertFalse(model.isBusy)
        store.loadContinuation?.resume(returning: AccountRecord(session: accountTestSession()))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(model.user)
        XCTAssertFalse(model.hasStoredSession)
        XCTAssertEqual(service.statusCalls, 0)
    }

    func testCancellationDuringFinalLoginSaveLeavesOnlyRevocableSession() async throws {
        let store = DelayedAccountStore()
        store.delayedSave = 2
        let service = AccountServiceDouble()
        let session = accountTestSession()
        service.confirmedUser = session.user
        let controller = AccountSessionController(service: service, store: store)
        let expected = controller.generation
        let task = Task { try await controller.accept(session, expected: expected) }
        try await waitUntil { store.saveContinuation != nil }
        controller.invalidateRequests()
        store.saveContinuation?.resume()
        do { try await task.value; XCTFail("取消后的登录不能成功") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(controller.user)
        XCTAssertEqual(store.record?.pendingRevocation, true)
    }

    func testConcurrentRefreshWaitsForPersistentCommit() async throws {
        let store = DelayedAccountStore()
        let session = accountTestSession()
        store.record = AccountRecord(session: session)
        store.delayedSave = 2
        let service = AccountServiceDouble()
        service.confirmedUser = session.user
        let controller = AccountSessionController(service: service, store: store)
        try await controller.restore()
        var completed = 0
        let first = Task { _ = try await controller.accessToken(forceRefresh: true); completed += 1 }
        try await waitUntil { service.refreshContinuation != nil }
        let second = Task { _ = try await controller.accessToken(forceRefresh: true); completed += 1 }
        service.refreshContinuation?.resume(returning: accountTestSession(suffix: "rotated"))
        try await waitUntil { store.saveContinuation != nil }
        XCTAssertEqual(completed, 0)
        XCTAssertEqual(service.refreshCalls, 1)
        store.saveContinuation?.resume()
        try await first.value
        try await second.value
        XCTAssertEqual(completed, 2)
        XCTAssertEqual(store.saves, 2)
        XCTAssertEqual(store.record?.pendingRevocation, false)
    }

    func testEmailActivityShowsSendingAndClearsAfterFailure() async throws {
        let model = AccountModel(service: AccountServiceDouble(), store: AccountMemoryStore())
        model.email = "unit@example.com"
        model.sendCode()
        XCTAssertEqual(model.emailActivity, .sendingCode)
        try await waitUntil { !model.isBusy }
        XCTAssertNil(model.emailActivity)
        XCTAssertNotNil(model.message)
    }

    func testCancelledLoginClearsItsActivityImmediately() async throws {
        let model = AccountModel(service: AccountServiceDouble(), store: AccountMemoryStore())
        model.email = "unit@example.com"
        model.code = "123456"
        model.login()
        XCTAssertEqual(model.emailActivity, .signingIn)
        model.close()
        XCTAssertNil(model.emailActivity)
        XCTAssertFalse(model.isBusy)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(model.emailActivity)
        XCTAssertNil(model.user)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("账号请求未进入预期状态")
        throw AccountError.invalidResponse
    }
}

@MainActor
private final class DelayedAccountStore: AccountSessionStore {
    var record: AccountRecord?
    var loads = 0
    var saves = 0
    var delayLoad = false
    var delayedSave: Int?
    var loadContinuation: CheckedContinuation<AccountRecord?, Never>?
    var saveContinuation: CheckedContinuation<Void, Never>?
    @MainActor func load() async throws -> AccountRecord? {
        loads += 1
        if delayLoad { return await withCheckedContinuation { loadContinuation = $0 } }
        return record
    }
    @MainActor func save(_ record: AccountRecord) async throws {
        saves += 1
        self.record = record
        if delayedSave == saves { await withCheckedContinuation { saveContinuation = $0 } }
    }
    @MainActor func remove() async throws { record = nil }
}
