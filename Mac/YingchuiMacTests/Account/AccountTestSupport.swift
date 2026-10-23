import Foundation
@testable import YingchuiMac

// 仅供单元测试的隔离替身，不进入应用或真实用户服务。
@MainActor
final class AccountMemoryStore: AccountSessionStore {
    var record: AccountRecord?
    var saves = 0
    var failure: AccountError?
    init(_ record: AccountRecord? = nil) { self.record = record }
    func load() throws -> AccountRecord? {
        if let failure { throw failure }
        return record
    }
    func save(_ record: AccountRecord) throws {
        if let failure { throw failure }
        saves += 1
        self.record = record
    }
    func remove() throws {
        if let failure { throw failure }
        record = nil
    }
}

@MainActor
final class AccountServiceDouble: AccountService {
    var availabilityMessage: String? { nil }
    var statusCalls = 0
    var confirmedUser: AccountUser?
    var refreshCalls = 0
    var revokeCalls = 0
    var revokeFailure: Error?
    var refreshContinuation: CheckedContinuation<AccountSession, Error>?
    var userContinuation: CheckedContinuation<AccountUser, Error>?
    var userContinuations: [CheckedContinuation<AccountUser, Error>] = []
    var deferUser = false
    func status() async throws -> AccountServiceStatus { statusCalls += 1; return .init(emailAvailable: true, appleAvailable: false) }
    func sendEmailCode(email: String) async throws -> EmailCodeReceipt { throw AccountError.unavailable("测试未配置发码") }
    func login(email: String, code: String) async throws -> AccountSession { throw AccountError.unavailable("测试未配置登录") }
    func currentUser(accessToken: String) async throws -> AccountUser {
        if deferUser { return try await withCheckedThrowingContinuation { userContinuation = $0; userContinuations.append($0) } }
        guard let confirmedUser else { throw AccountError.invalidResponse }
        return confirmedUser
    }
    func refresh(refreshToken: String) async throws -> AccountSession {
        refreshCalls += 1
        return try await withCheckedThrowingContinuation { refreshContinuation = $0 }
    }
    func revoke(refreshToken: String) async throws {
        revokeCalls += 1
        if let revokeFailure { throw revokeFailure }
    }
    func appleChallenge() async throws -> AppleAccountChallenge { throw AccountError.unavailable("测试未配置 Apple") }
    func exchangeApple(challenge: AppleAccountChallenge, credential: AppleAccountCredential) async throws -> AccountSession {
        throw AccountError.unavailable("测试未配置 Apple")
    }
}

func accountTestSession(accessExpiry: Date = Date().addingTimeInterval(900), suffix: String = "first") -> AccountSession {
    AccountSession(user: AccountUser(id: "test-user", nickname: "", email: "unit@example.com"), sessionID: "test-session",
                   accessToken: "unit-access-\(suffix)", refreshToken: "unit-refresh-\(suffix)",
                   accessExpiresAt: accessExpiry, refreshExpiresAt: Date().addingTimeInterval(86_400), appleUserID: nil)
}

actor AccountTransportDouble: AccountHTTPTransport {
    var requests: [URLRequest] = []
    let status: Int
    let body: Data
    let headers: [String: String]
    init(status: Int = 200, json: String, headers: [String: String] = ["Content-Type": "application/json"]) {
        self.status = status
        body = Data(json.utf8)
        self.headers = headers
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status,
                                                                   httpVersion: nil, headerFields: headers) else {
            throw AccountError.invalidResponse
        }
        return (body, response)
    }
}
