import Foundation

public struct HostCredential: Codable, Equatable, Sendable {
    public let token: String
    public let certificateFingerprint: String

    public init(token: String, certificateFingerprint: String) throws {
        guard Data(base64Encoded: token)?.count == 32,
              Data(base64Encoded: certificateFingerprint)?.count == 32 else {
            throw HostTrustError.incompleteCredential
        }
        self.token = token
        self.certificateFingerprint = certificateFingerprint
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(token: values.decode(String.self, forKey: .token),
                      certificateFingerprint: values.decode(String.self, forKey: .certificateFingerprint))
    }
}

public enum HostTrustError: LocalizedError {
    case incompleteCredential
    case invalidHost
    case ambiguousLegacyCredential

    public var errorDescription: String? {
        switch self {
        case .incompleteCredential: "配对凭据不完整或已损坏，请重置信任后重新配对"
        case .invalidHost: "配对主机编号无效"
        case .ambiguousLegacyCredential: "同一证书存在冲突的旧配对记录，请重置信任后重新配对"
        }
    }
}

/// 整份记录一次写入 Keychain，写入失败时不发布新内存状态。
public final class HostTrustStore {
    private let read: () throws -> Data?
    private let write: (Data) throws -> Void
    private var records: [String: HostCredential] = [:]

    public init(read: @escaping () throws -> Data?, write: @escaping (Data) throws -> Void) {
        self.read = read
        self.write = write
    }

    public func load() throws -> Bool {
        guard let data = try read() else { return false }
        let decoded = try JSONDecoder().decode([String: HostCredential].self, from: data)
        guard decoded.keys.allSatisfy(Self.isValidStoredKey) else {
            throw HostTrustError.invalidHost
        }
        records = decoded
        return true
    }

    public func credential(for hostID: String) -> HostCredential? {
        guard UUID(uuidString: hostID) != nil else { return nil }
        return records[hostID]
    }

    /// 名称索引只用于寻找证书精确匹配的旧记录，不能直接授予新主机信任。
    public func legacyCredential(matching fingerprint: String) throws -> HostCredential? {
        let matches = records.filter {
            UUID(uuidString: $0.key) == nil && $0.value.certificateFingerprint == fingerprint
        }.map(\.value)
        guard let first = matches.first else { return nil }
        guard matches.allSatisfy({ $0 == first }) else { throw HostTrustError.ambiguousLegacyCredential }
        return first
    }

    /// 仅在 TLS 证书匹配、主机编号匹配且主机确认令牌有效后调用。
    public func bindLegacyCredential(_ credential: HostCredential, to hostID: String) throws {
        guard UUID(uuidString: hostID) != nil else { throw HostTrustError.invalidHost }
        guard try legacyCredential(matching: credential.certificateFingerprint) == credential,
              records[hostID] == nil || records[hostID] == credential else {
            throw HostTrustError.incompleteCredential
        }
        var updated = records.filter { UUID(uuidString: $0.key) != nil || $0.value != credential }
        updated[hostID] = credential
        try commit(updated)
    }

    public func save(_ credential: HostCredential, for hostID: String) throws {
        guard UUID(uuidString: hostID) != nil else { throw HostTrustError.invalidHost }
        var updated = records.filter {
            UUID(uuidString: $0.key) != nil || $0.value.certificateFingerprint != credential.certificateFingerprint
        }
        updated[hostID] = credential
        try commit(updated)
    }

    public func remove(hostID: String) throws {
        var updated = records
        if let removed = updated.removeValue(forKey: hostID) {
            updated = updated.filter {
                UUID(uuidString: $0.key) != nil || $0.value.certificateFingerprint != removed.certificateFingerprint
            }
        }
        try commit(updated)
    }

    public func removeAll() throws { try commit([:]) }

    public func migrate(tokens: [String: String], pins: [String: String]) throws {
        guard Set(tokens.keys) == Set(pins.keys) else { throw HostTrustError.incompleteCredential }
        var migrated: [String: HostCredential] = [:]
        for (hostID, token) in tokens {
            guard Self.isValidStoredKey(hostID) else { throw HostTrustError.invalidHost }
            guard let pin = pins[hostID] else { throw HostTrustError.incompleteCredential }
            migrated[hostID] = try HostCredential(token: token, certificateFingerprint: pin)
        }
        try commit(migrated)
    }

    private func commit(_ updated: [String: HostCredential]) throws {
        try write(JSONEncoder().encode(updated))
        records = updated
    }

    private static func isValidStoredKey(_ key: String) -> Bool {
        !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && key.utf8.count <= 1_024 &&
        !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
