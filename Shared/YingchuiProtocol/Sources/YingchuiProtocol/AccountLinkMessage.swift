import Foundation

/// 仅通过完成设备信任校验的 TLS 控制连接传输，不包含长期账号令牌。
public struct AccountLinkMessage: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case state, request, grant, result }
    public let phase: Phase
    public let id: UUID
    public let userID: String?
    public let acceptsLogin: Bool?
    public let clientID: String?
    public let challenge: String?
    public let grant: String?
    public let expiresIn: Int?
    public let errorCode: String?

    public init(phase: Phase, id: UUID = UUID(), userID: String? = nil, acceptsLogin: Bool? = nil,
                clientID: String? = nil, challenge: String? = nil, grant: String? = nil,
                expiresIn: Int? = nil, errorCode: String? = nil) {
        self.phase = phase; self.id = id; self.userID = userID; self.acceptsLogin = acceptsLogin
        self.clientID = clientID; self.challenge = challenge; self.grant = grant
        self.expiresIn = expiresIn; self.errorCode = errorCode
    }

    public var isValid: Bool {
        let validUser = userID.map { !$0.isEmpty && $0.utf8.count <= 256 } ?? true
        let validClient = clientID.map { ["com.yingchui.interconnect.mac", "com.yingchui.interconnect.pad"].contains($0) } ?? true
        guard validUser, validClient else { return false }
        switch phase {
        case .state:
            return acceptsLogin != nil && clientID != nil && challenge == nil && grant == nil
                && errorCode == nil && expiresIn == nil && !(acceptsLogin == true && userID != nil)
        case .request:
            return clientID != nil && challenge.map(Self.isChallenge) == true && grant == nil
                && userID != nil && acceptsLogin == nil && expiresIn == nil && errorCode == nil
        case .grant:
            return userID != nil && grant.map { (32...512).contains($0.utf8.count) } == true
                && expiresIn.map { (1...60).contains($0) } == true && challenge == nil
                && clientID == nil && acceptsLogin == nil && errorCode == nil
        case .result:
            return grant == nil && challenge == nil && (errorCode?.utf8.count ?? 0) <= 64
                && userID == nil && clientID == nil && acceptsLogin == nil && expiresIn == nil
        }
    }

    public static func isChallenge(_ value: String) -> Bool {
        value.utf8.count == 43 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
}
