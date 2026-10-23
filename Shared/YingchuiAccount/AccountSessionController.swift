import Combine
import Foundation

@MainActor
final class AccountSessionController: ObservableObject {
    @Published private(set) var user: AccountUser?
    @Published private(set) var needsLogoutRetry = false
    private(set) var generation = UUID()
    @Published private var record: AccountRecord?
    private var refreshTask: Task<AccountSession, Error>?
    private let service: any AccountService
    private let store: any AccountSessionStore

    init(service: any AccountService, store: any AccountSessionStore) {
        self.service = service
        self.store = store
    }

    var hasStoredSession: Bool { record != nil }

    func invalidateRequests() {
        generation = UUID()
        if refreshTask != nil, let current = record {
            // 刷新提交前已落盘待撤销标记；取消后内存也不能再使用旧令牌。
            record = AccountRecord(session: current.session, pendingRevocation: true)
            needsLogoutRetry = true
            user = nil
        }
        refreshTask?.cancel()
        refreshTask = nil
    }

    func check(_ expected: UUID) throws {
        try Task.checkCancellation()
        guard expected == generation else { throw CancellationError() }
    }

    func restore() async throws {
        let expected = generation
        guard let saved = try await store.load() else { try check(expected); return }
        try check(expected)
        record = saved
        if saved.pendingRevocation {
            needsLogoutRetry = true
            try await signOut()
            return
        }
        do {
            try saved.session.validate(requireUsableAccess: false)
            if let appleUserID = saved.session.appleUserID {
                try await AppleAccountAuthorization.requireAuthorized(userID: appleUserID)
                try check(expected)
            }
            let token = try await accessToken()
            let confirmed = try await service.currentUser(accessToken: token)
            try check(expected)
            try confirmed.validate()
            guard confirmed.id == saved.session.user.id else { throw AccountError.invalidResponse }
            user = confirmed
        } catch {
            try check(expected)
            user = nil
            if error as? AccountError == .expired || error as? AccountError == .unauthorized {
                try await store.remove()
                try check(expected)
                record = nil
            }
            throw error
        }
    }

    // 只更新经服务端确认的身份，不改写令牌或邮箱登录方式。
    func refreshProfile(expected: UUID, boundTo previous: AccountUser? = nil) async throws {
        try check(expected)
        guard let current = user else { throw AccountError.unauthorized }
        let token = try await accessToken()
        try check(expected)
        let confirmed = try await service.currentUser(accessToken: token)
        try check(expected)
        try confirmed.validate()
        guard confirmed.id == current.id else { throw AccountError.invalidResponse }
        if let previous { try confirmed.validateAppleBinding(to: previous) }
        user = confirmed
    }

    func accept(_ session: AccountSession, expected: UUID,
                authorized: @escaping @MainActor () -> Bool = { true }) async throws {
        func checkAcceptance() throws {
            try check(expected)
            guard authorized() else { throw CancellationError() }
        }
        try checkAcceptance()
        guard record == nil else { throw AccountError.operationInProgress }
        try session.validate()
        let confirmed = try await service.currentUser(accessToken: session.accessToken)
        try checkAcceptance()
        guard record == nil else { throw AccountError.operationInProgress }
        try confirmed.validate()
        guard confirmed.id == session.user.id else { throw AccountError.invalidResponse }
        let pending = AccountRecord(session: session, pendingRevocation: true)
        record = pending
        do {
            try await store.save(pending)
            try checkAcceptance()
            let saved = AccountRecord(session: session)
            try await store.save(saved)
            try checkAcceptance()
            record = saved
            user = confirmed
        } catch {
            // 取消或写入失败不能让磁盘中的会话在下次启动时自动恢复。
            if record?.session == session {
                record = pending
                needsLogoutRetry = true
                try await store.save(pending)
            }
            throw error
        }
    }

    func accessToken(now: Date = Date(), forceRefresh: Bool = false) async throws -> String {
        let expected = generation
        if let existing = refreshTask {
            let session = try await existing.value
            try check(expected)
            return session.accessToken
        }
        guard let current = record, !current.pendingRevocation else { throw AccountError.unauthorized }
        try current.session.validate(now: now, requireUsableAccess: false)
        if !forceRefresh && current.session.accessExpiresAt > now.addingTimeInterval(30) { return current.session.accessToken }
        // 创建任务先于任何存储等待；所有调用者等待同一次网络请求与持久化提交。
        let task = Task { try await self.performRefresh(current, expected: expected, now: now) }
        refreshTask = task
        defer { if generation == expected { refreshTask = nil } }
        let refreshed = try await task.value
        try check(expected)
        return refreshed.accessToken
    }

    private func performRefresh(_ current: AccountRecord, expected: UUID, now: Date) async throws -> AccountSession {
        do {
            try await store.save(AccountRecord(session: current.session, pendingRevocation: true))
            try check(expected)
            let response = try await service.refresh(refreshToken: current.session.refreshToken)
            try check(expected)
            if current.session.appleUserID != nil, !response.user.identities.contains("apple") {
                throw AccountError.invalidResponse
            }
            let refreshed = response.withAppleUserID(current.session.appleUserID)
            try refreshed.validate(now: max(now, Date()))
            guard refreshed.sessionID == current.session.sessionID,
                  refreshed.user.id == current.session.user.id,
                  refreshed.appleUserID == current.session.appleUserID else { throw AccountError.invalidResponse }
            record = AccountRecord(session: refreshed, pendingRevocation: true)
            let saved = AccountRecord(session: refreshed)
            try await store.save(saved)
            try check(expected)
            record = saved
            return refreshed
        } catch {
            // 存储现在是异步的：取消期间已经写入的会话也必须保持待撤销，不能恢复登录。
            if record?.session.sessionID == current.session.sessionID {
                user = nil
                if error as? AccountError == .unauthorized, generation == expected {
                    try await store.remove()
                    try check(expected)
                    record = nil
                } else {
                    let pending = AccountRecord(session: record?.session ?? current.session, pendingRevocation: true)
                    record = pending
                    needsLogoutRetry = true
                    try await store.save(pending)
                }
            }
            try check(expected)
            if error as? AccountError == .unauthorized { throw error }
            throw AccountError.refreshUncertain
        }
    }

    func signOut() async throws {
        invalidateRequests()
        user = nil
        guard let current = record else { return }
        let pending = AccountRecord(session: current.session, pendingRevocation: true)
        needsLogoutRetry = true
        // 撤销意图先持久化，断网或进程退出后也不能恢复旧账号。
        let expected = generation
        record = pending
        try await store.save(pending)
        try check(expected)
        if pending.session.refreshExpiresAt > Date() {
            do {
                try await service.revoke(refreshToken: pending.session.refreshToken)
            } catch {
                try check(expected)
                // 仅明确的已失效响应等同于无可用会话，网络失败保留待撤销记录。
                guard error as? AccountError == .unauthorized else { throw error }
            }
        }
        try check(expected)
        try await store.remove()
        try check(expected)
        record = nil
        needsLogoutRetry = false
    }
}
