import AuthenticationServices
import Foundation

extension AccountModel {
    func bindApple(window: ASPresentationAnchor?) {
        run {
            guard let original = self.user, original.identities.contains("email") else { throw AccountError.unauthorized }
            guard !original.identities.contains("apple") else { return }
            let expected = self.sessions.generation
            // 每次点击确认当前服务能力，部署启用后无需重启客户端。
            try await self.updateAvailability()
            try self.sessions.check(expected)
            guard self.appleBindingAvailable else { throw AccountError.unavailable("Apple 账户绑定尚未开放。") }
            guard let window else { throw AccountError.appleAuthorizationFailed }
            try AppleAccountAuthorization.requireCapability()
            let token = try await self.sessions.accessToken()
            try self.sessions.check(expected)
            let challenge = try await self.service.appleBindingChallenge(accessToken: token)
            try self.sessions.check(expected)
            let credential = try await self.apple.authorize(challenge: challenge, window: window)
            try self.sessions.check(expected)
            // 系统授权可能持续数分钟；保持同一会话并取得有效令牌。
            let freshToken = try await self.sessions.accessToken()
            try self.sessions.check(expected)
            self.needsProfileRefresh = true
            let bound = try await self.service.bindApple(accessToken: freshToken, challenge: challenge, credential: credential)
            try self.sessions.check(expected)
            try bound.validateAppleBinding(to: original)
            try await self.sessions.refreshProfile(expected: expected, boundTo: original)
            self.needsProfileRefresh = false
            self.message = "Apple 账户已绑定。"
        }
    }

    func refreshAccountProfile() {
        run(checking: true) {
            // 同账号另一端完成绑定后，打开账户即获取最新身份。
            try await self.sessions.refreshProfile(expected: self.sessions.generation)
            self.needsProfileRefresh = false
            try await self.updateAvailability()
        }
    }
}
