import Foundation

@MainActor
protocol AccountService {
    var availabilityMessage: String? { get }
    func status() async throws -> AccountServiceStatus
    func sendEmailCode(email: String) async throws -> EmailCodeReceipt
    func login(email: String, code: String) async throws -> AccountSession
    func currentUser(accessToken: String) async throws -> AccountUser
    func refresh(refreshToken: String) async throws -> AccountSession
    func revoke(refreshToken: String) async throws
    func createDeviceLink(accessToken: String, recipientClientID: String, challenge: String) async throws -> AccountDeviceGrant
    func exchangeDeviceLink(grant: String, verifier: String) async throws -> AccountSession
    func appleBindingChallenge(accessToken: String) async throws -> AppleAccountChallenge
    func bindApple(accessToken: String, challenge: AppleAccountChallenge, credential: AppleAccountCredential) async throws -> AccountUser
    func appleChallenge() async throws -> AppleAccountChallenge
    func exchangeApple(challenge: AppleAccountChallenge, credential: AppleAccountCredential) async throws -> AccountSession
}

@MainActor
func makeAccountService() -> any AccountService {
    do { return try AccountHTTPService(configuration: AccountConfiguration.load()) }
    catch { return UnavailableAccountService(availabilityMessage: accountErrorMessage(error)) }
}

struct UnavailableAccountService: AccountService {
    let availabilityMessage: String?
    private var failure: AccountError { .unavailable(availabilityMessage ?? "登录服务不可用。") }
    func status() async throws -> AccountServiceStatus { throw failure }
    func sendEmailCode(email: String) async throws -> EmailCodeReceipt { throw failure }
    func login(email: String, code: String) async throws -> AccountSession { throw failure }
    func currentUser(accessToken: String) async throws -> AccountUser { throw failure }
    func refresh(refreshToken: String) async throws -> AccountSession { throw failure }
    func revoke(refreshToken: String) async throws { throw failure }
    func appleChallenge() async throws -> AppleAccountChallenge { throw failure }
    func exchangeApple(challenge: AppleAccountChallenge, credential: AppleAccountCredential) async throws -> AccountSession { throw failure }
}

extension AccountService {
    func appleBindingChallenge(accessToken: String) async throws -> AppleAccountChallenge {
        throw AccountError.unavailable("Apple 账户绑定尚未开放。")
    }
    func bindApple(accessToken: String, challenge: AppleAccountChallenge, credential: AppleAccountCredential) async throws -> AccountUser {
        throw AccountError.unavailable("Apple 账户绑定尚未开放。")
    }
    func createDeviceLink(accessToken: String, recipientClientID: String, challenge: String) async throws -> AccountDeviceGrant {
        throw AccountError.unavailable("账号联动尚未开放。")
    }
    func exchangeDeviceLink(grant: String, verifier: String) async throws -> AccountSession {
        throw AccountError.unavailable("账号联动尚未开放。")
    }
}
