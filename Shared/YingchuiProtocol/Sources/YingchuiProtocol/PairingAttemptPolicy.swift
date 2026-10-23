import Foundation

/// 所有会话共用同一个预算，换连接或轮换配对码不会清空失败记录。
public struct PairingAttemptPolicy: Sendable {
    private var attempts: [TimeInterval] = []
    private var issuedAt: TimeInterval
    public let maximumAttempts: Int
    public let attemptWindow: TimeInterval
    public let codeLifetime: TimeInterval

    public init(now: TimeInterval, maximumAttempts: Int = 5,
                attemptWindow: TimeInterval = 60, codeLifetime: TimeInterval = 300) {
        issuedAt = now
        self.maximumAttempts = max(1, maximumAttempts)
        self.attemptWindow = max(1, attemptWindow)
        self.codeLifetime = max(1, codeLifetime)
    }

    public func isExpired(at now: TimeInterval) -> Bool { now - issuedAt >= codeLifetime }

    public mutating func rotateCode(at now: TimeInterval) { issuedAt = now }

    public mutating func consumeAttempt(at now: TimeInterval) throws {
        guard !isExpired(at: now) else { throw PairingAttemptError.expired }
        attempts.removeAll { now - $0 >= attemptWindow }
        guard attempts.count < maximumAttempts else { throw PairingAttemptError.rateLimited }
        attempts.append(now)
    }
}

public enum PairingAttemptError: String, LocalizedError, Sendable {
    case expired = "pairing_code_expired"
    case rateLimited = "pairing_rate_limited"

    public var errorDescription: String? {
        switch self {
        case .expired: "配对码已过期，请查看 Mac 上的新配对码"
        case .rateLimited: "配对尝试过于频繁，请一分钟后重试"
        }
    }
}
