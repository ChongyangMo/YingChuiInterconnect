import Foundation
import Security

public enum SecureStoreError: LocalizedError, Equatable {
    case keychain(OSStatus)
    case unexpectedValue

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "Keychain 操作失败（\(status)）"
        case .unexpectedValue:
            return "Keychain 返回了无效数据"
        }
    }
}

public enum SecureStore {
    public static func data(service: String, account: String) throws -> Data? {
        let query = baseQuery(service: service, account: account).merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]) { _, new in new } as CFDictionary
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecureStoreError.keychain(status) }
        guard let data = result as? Data else { throw SecureStoreError.unexpectedValue }
        return data
    }

    public static func set(_ data: Data, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw SecureStoreError.keychain(updateStatus) }

        let insert = query.merging(attributes) { _, new in new }
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw SecureStoreError.keychain(addStatus) }
    }

    public static func remove(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureStoreError.keychain(status)
        }
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
