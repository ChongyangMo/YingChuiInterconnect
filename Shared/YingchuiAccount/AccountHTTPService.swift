import Foundation

@MainActor
final class AccountHTTPService: AccountService {
    let availabilityMessage: String? = nil
    let configuration: AccountConfiguration
    private let transport: any AccountHTTPTransport

    init(configuration: AccountConfiguration, transport: (any AccountHTTPTransport)? = nil) throws {
        try configuration.validate()
        self.configuration = configuration
        self.transport = transport ?? AccountURLSessionTransport(useSystemProxy: configuration.useSystemProxy)
    }

    func status() async throws -> AccountServiceStatus {
        let value: StatusResponse = try await json("status")
        guard value.version == configuration.contractVersion else { throw AccountError.invalidResponse }
        return AccountServiceStatus(emailAvailable: value.email_available, appleAvailable: configuration.appleEnabled && value.apple_available, deviceLinkAvailable: value.device_link_available == true,
                                    appleBindingAvailable: value.apple_binding_available == true)
    }

    func sendEmailCode(email: String) async throws -> EmailCodeReceipt {
        let started = Date()
        let value: CodeResponse = try await json("email/code", body: ["email": email, "purpose": "login"])
        guard value.expires_in > 0, value.expires_in <= 300, value.retry_after > 0,
              value.retry_after <= 3600 else { throw AccountError.invalidResponse }
        return EmailCodeReceipt(email: email, expiresAt: started.addingTimeInterval(TimeInterval(value.expires_in)),
                                resendAt: started.addingTimeInterval(TimeInterval(value.retry_after)))
    }

    func login(email: String, code: String) async throws -> AccountSession {
        let started = Date()
        let response: SessionResponse = try await json("email/login", body: ["email": email, "code": code])
        return try response.session(started: started)
    }

    func currentUser(accessToken: String) async throws -> AccountUser {
        let response: UserResponse = try await json("me", accessToken: accessToken)
        return try response.user()
    }

    func refresh(refreshToken: String) async throws -> AccountSession {
        let started = Date()
        let response: SessionResponse = try await json("refresh", body: ["refresh_token": refreshToken])
        return try response.session(started: started)
    }

    func revoke(refreshToken: String) async throws {
        let (data, response) = try await request("logout", body: ["refresh_token": refreshToken])
        guard response.statusCode == 204, data.isEmpty else { throw AccountError.invalidResponse }
    }

    // 预备实现：默认配置关闭；后端完成契约、部署及验收后才显式启用。
    func appleChallenge() async throws -> AppleAccountChallenge {
        guard configuration.appleEnabled else { throw AccountError.unavailable("Apple 登录尚未开放。") }
        let started = Date()
        let response: ChallengeResponse = try await json("apple/challenge", body: [:])
        guard !response.challenge_id.isEmpty, !response.nonce.isEmpty,
              response.expires_in > 0, response.expires_in <= 300 else { throw AccountError.invalidResponse }
        return AppleAccountChallenge(id: response.challenge_id, requestNonce: response.nonce,
                                     expiresAt: started.addingTimeInterval(TimeInterval(response.expires_in)))
    }
    func exchangeApple(challenge: AppleAccountChallenge, credential: AppleAccountCredential) async throws -> AccountSession {
        guard configuration.appleEnabled else { throw AccountError.unavailable("Apple 登录尚未开放。") }
        guard challenge.expiresAt > Date() else { throw AccountError.expired }
        let name = [credential.givenName, credential.familyName].compactMap { $0 }.joined(separator: " ")
        var body = ["challenge_id": challenge.id, "identity_token": credential.identityToken,
                    "authorization_code": credential.authorizationCode]
        if !name.isEmpty { body["nickname"] = name }
        let started = Date()
        let response: SessionResponse = try await json("apple/login", body: body)
        let session = try response.session(started: started)
        guard session.user.identities.contains("apple") else { throw AccountError.invalidResponse }
        return session.withAppleUserID(credential.userID)
    }

    func json<T: Decodable>(_ path: String, body: [String: String]? = nil, accessToken: String? = nil) async throws -> T {
        let (data, response) = try await request(path, body: body, accessToken: accessToken)
        guard response.statusCode == 200,
              response.mimeType?.lowercased() == "application/json" else { throw AccountError.invalidResponse }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw AccountError.invalidResponse }
    }

    private func request(_ path: String, body: [String: String]? = nil, accessToken: String? = nil) async throws -> (Data, HTTPURLResponse) {
        let url = configuration.baseURL.appendingPathComponent("api/auth/v1").appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.setValue(configuration.clientID, forHTTPHeaderField: "X-Client-ID")
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await transport.send(request)
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else { throw try decodeError(data, response: response) }
        return (data, response)
    }

    private func decodeError(_ data: Data, response: HTTPURLResponse) throws -> AccountError {
        guard response.statusCode != 404 else { return .unavailable("登录服务尚未部署。") }
        let value: ErrorResponse
        do { value = try JSONDecoder().decode(ErrorResponse.self, from: data) }
        catch { throw AccountError.invalidResponse }
        switch (response.statusCode, value.error.code) {
        case (401, "invalid_code"): return .invalidCode
        case (401, "invalid_access_token"), (401, "invalid_refresh_token"), (401, "refresh_reused"): return .unauthorized
        case (401, "invalid_device_link_grant"): return .unavailable("账号联动凭据已失效，请重新连接后重试。")
        case (503, "device_link_unavailable"): return .unavailable("账号联动尚未开放。")
        case (503, "apple_binding_unavailable"): return .unavailable("Apple 账户绑定尚未开放。")
        case (409, "apple_identity_conflict"): return .unavailable("此 Apple 账户已绑定其他账号。")
        case (401, "invalid_apple_binding_challenge"), (401, "invalid_apple_credential"):
            return .unavailable("Apple 绑定授权已失效，请重新授权。")
        case (409, "identity_conflict"): return .identityConflict
        case (429, "rate_limited"):
            guard let seconds = value.error.retry_after, seconds > 0,
                  let header = response.value(forHTTPHeaderField: "Retry-After"), Int(header) == seconds else {
                throw AccountError.invalidResponse
            }
            return .rateLimited(Date().addingTimeInterval(TimeInterval(seconds)))
        case (503, "email_unavailable"): return .unavailable("邮件服务暂不可用，请稍后重试。")
        case (503, "apple_unavailable"): return .unavailable("Apple 登录尚未开放。")
        case (503, "service_unavailable"): return .unavailable("账号服务暂不可用，请稍后重试。")
        case (400, "invalid_request"): return .unavailable("账号请求无效，请检查输入。")
        default: return .invalidResponse
        }
    }
}

private struct StatusResponse: Decodable { let version: String; let email_available: Bool; let apple_available: Bool; let device_link_available: Bool?; let apple_binding_available: Bool? }
private struct ChallengeResponse: Decodable { let challenge_id: String; let nonce: String; let expires_in: Int }
private struct CodeResponse: Decodable { let expires_in: Int; let retry_after: Int }
private struct ErrorResponse: Decodable {
    let error: Detail
    struct Detail: Decodable { let code: String; let message: String; let retry_after: Int? }
}
struct UserResponse: Decodable {
    let user_id: String
    let nickname: String
    let email: String?
    let identities: [String]
    let legacy_profile_ids: [String]
    let vip: Bool?

    func user() throws -> AccountUser {
        guard identities.contains("email") || identities.contains("apple") else { throw AccountError.invalidResponse }
        if identities.contains("email"), email?.isEmpty != false { throw AccountError.invalidResponse }
        let user = AccountUser(id: user_id, nickname: nickname, email: email, identities: identities, vip: vip)
        try user.validate()
        return user
    }
}
struct SessionResponse: Decodable {
    let token_type: String
    let access_token: String
    let refresh_token: String
    let expires_in: Int
    let refresh_expires_in: Int
    let session_id: String
    let is_new_user: Bool
    let user: UserResponse

    func session(started: Date) throws -> AccountSession {
        guard token_type == "Bearer", expires_in > 0, expires_in <= 900,
              refresh_expires_in > 0, refresh_expires_in <= 2_592_000 else { throw AccountError.invalidResponse }
        let session = AccountSession(user: try user.user(), sessionID: session_id, accessToken: access_token,
            refreshToken: refresh_token, accessExpiresAt: started.addingTimeInterval(TimeInterval(expires_in)),
            refreshExpiresAt: started.addingTimeInterval(TimeInterval(refresh_expires_in)), appleUserID: nil)
        try session.validate()
        return session
    }
}
