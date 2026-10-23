import Foundation

// 客户端内部模型；正式接口的 JSON 映射由后续契约适配器负责。
struct AccountUser: Codable, Equatable, Sendable {
    let id: String
    let nickname: String
    var displayName: String { nickname.isEmpty ? (email ?? "账号") : nickname }
    let email: String?
    var identities: [String] = ["email"]
    // nil 表示服务端尚未提供资格信息，不等同于非 VIP。
    var vip: Bool? = nil

    func validate() throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !identities.isEmpty, identities.allSatisfy({ ["email", "apple", "wechat"].contains($0) }) else {
            throw AccountError.invalidResponse
        }
    }
}

struct AccountSession: Codable, Equatable, Sendable {
    let user: AccountUser
    let sessionID: String
    let accessToken: String
    let refreshToken: String
    let accessExpiresAt: Date
    let refreshExpiresAt: Date
    let appleUserID: String?

    func validate(now: Date = Date(), requireUsableAccess: Bool = true, requireLiveRefresh: Bool = true) throws {
        try user.validate()
        guard !sessionID.isEmpty, !accessToken.isEmpty, !refreshToken.isEmpty,
              accessToken != user.id, refreshToken != user.id,
              accessToken != user.email, refreshToken != user.email,
              accessToken != refreshToken,
              accessExpiresAt.timeIntervalSince1970.isFinite,
              refreshExpiresAt.timeIntervalSince1970.isFinite,
              accessExpiresAt <= refreshExpiresAt else { throw AccountError.invalidResponse }
        guard !requireLiveRefresh || refreshExpiresAt > now, !requireUsableAccess || accessExpiresAt > now else {
            throw AccountError.expired
        }
    }
}

struct EmailCodeReceipt: Sendable {
    let email: String
    let expiresAt: Date
    let resendAt: Date
}

struct AppleAccountChallenge: Sendable {
    let id: String
    // 后端契约适配器必须明确 nonce 的原文/哈希约定，此处直接传给 Apple。
    let requestNonce: String
    let expiresAt: Date
}

struct AppleAccountCredential: Sendable {
    let userID: String
    let identityToken: String
    let authorizationCode: String
    let givenName: String?
    let familyName: String?
}

enum AccountError: Error, LocalizedError, Equatable {
    case unavailable(String)
    case invalidConfiguration
    case invalidResponse
    case invalidEmail
    case missingCode
    case invalidCode
    case identityConflict
    case refreshUncertain
    case expired
    case unauthorized
    case rateLimited(Date)
    case keychain(Int32)
    case appleCapabilityMissing
    case appleAuthorizationFailed
    case appleStateMismatch
    case operationInProgress

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        case .invalidConfiguration: "账号服务配置无效。"
        case .invalidResponse: "账号服务返回的数据无效。"
        case .invalidEmail: "请输入有效邮箱。"
        case .missingCode: "请输入六位数字验证码。"
        case .invalidCode: "验证码无效或已过期，请重新验证。"
        case .identityConflict: "账号身份存在冲突，请联系支持。"
        case .refreshUncertain: "会话刷新未完成，请退出后重新登录。"
        case .expired: "登录已过期，请重新登录。"
        case .unauthorized: "登录已失效，请重新登录。"
        case .rateLimited: "操作过于频繁，请稍后重试。"
        case .keychain(let status): "钥匙串操作失败（\(status)）。"
        case .appleCapabilityMissing: "当前版本尚未配置 Apple 登录能力。"
        case .appleAuthorizationFailed: "Apple 授权失败，请重试。"
        case .appleStateMismatch: "Apple 授权校验失败，请重新登录。"
        case .operationInProgress: "正在处理账号请求。"
        }
    }
}

func accountErrorMessage(_ error: Error) -> String {
    if let error = error as? AccountError { return error.localizedDescription }
    if error is DecodingError { return AccountError.invalidResponse.localizedDescription }
    if let error = error as? URLError {
        return error.code == .timedOut ? "账号请求超时，请重试。" : "无法连接账号服务，请检查网络。"
    }
    // 不直接展示服务器正文或包含令牌的底层错误。
    return "账号操作失败，请重试。"
}

struct AccountRecord: Codable, Equatable, Sendable {
    let session: AccountSession
    var pendingRevocation = false
}

struct AccountServiceStatus: Sendable {
    let emailAvailable: Bool
    let appleAvailable: Bool
    var deviceLinkAvailable = false
    var appleBindingAvailable = false
}

extension AccountSession {
    func withAppleUserID(_ value: String?) -> AccountSession {
        AccountSession(user: user, sessionID: sessionID, accessToken: accessToken, refreshToken: refreshToken,
                       accessExpiresAt: accessExpiresAt, refreshExpiresAt: refreshExpiresAt, appleUserID: value)
    }
}
