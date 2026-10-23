import Foundation
import Security

protocol AccountSessionStore: Sendable {
    func load() async throws -> AccountRecord?
    func save(_ record: AccountRecord) async throws
    func remove() async throws
}

actor AccountKeychainStore: AccountSessionStore {
    // 与局域网 TLS 密钥和可信设备存储完全分离。
    let service: String
    private let account = "business-session.v1"

    init(service: String = AccountConfiguration.defaultClientID + ".account") {
        self.service = service
    }

    // 当前为独立签名 Mac 应用，固定使用系统登录钥匙串及其签名 ACL。
    // 不同步到 iCloud，不在失败时切换存储后端，也不使用普通文件保存凭据。
    private var query: [String: Any] {
        var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
#if os(macOS)
        value[kSecUseDataProtectionKeychain as String] = false
#endif
        return value
    }

    func load() throws -> AccountRecord? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AccountError.keychain(status) }
        guard let data = result as? Data else { throw AccountError.invalidResponse }
        return try JSONDecoder().decode(AccountRecord.self, from: data)
    }

    func save(_ record: AccountRecord) throws {
        try record.session.validate(requireUsableAccess: false, requireLiveRefresh: false)
        let values: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(record)
        ]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query.merging(values) { _, new in new }
#if os(iOS)
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
#endif
            let status = SecItemAdd(addition as CFDictionary, nil)
            guard status == errSecSuccess else { throw AccountError.keychain(status) }
        } else if status != errSecSuccess {
            throw AccountError.keychain(status)
        }
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AccountError.keychain(status)
        }
    }
}
