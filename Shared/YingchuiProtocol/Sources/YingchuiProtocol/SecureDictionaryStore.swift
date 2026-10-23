import Foundation

public enum SecureDictionaryStoreError: LocalizedError {
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .invalidData:
            return "安全凭据数据已损坏"
        }
    }
}

public enum SecureDictionaryStore {
    public static func load(
        service: String,
        account: String,
        legacyDefaultsKey: String? = nil,
        defaults: UserDefaults = .standard
    ) throws -> [String: String] {
        if let data = try SecureStore.data(service: service, account: account) {
            do {
                return try JSONDecoder().decode([String: String].self, from: data)
            } catch {
                throw SecureDictionaryStoreError.invalidData
            }
        }

        guard let legacyDefaultsKey else { return [:] }
        let legacy = defaults.dictionary(forKey: legacyDefaultsKey) as? [String: String] ?? [:]
        guard !legacy.isEmpty else { return [:] }
        try save(legacy, service: service, account: account)
        defaults.removeObject(forKey: legacyDefaultsKey)
        return legacy
    }

    public static func save(
        _ values: [String: String],
        service: String,
        account: String
    ) throws {
        if values.isEmpty {
            try SecureStore.remove(service: service, account: account)
            return
        }
        let data = try JSONEncoder().encode(values)
        try SecureStore.set(data, service: service, account: account)
    }
}
