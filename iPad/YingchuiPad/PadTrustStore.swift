import Foundation
import YingchuiProtocol

/// 仅由连接模型的网络队列使用；初始化在网络服务启动前完成。
final class PadTrustStore {
    private static let service = "com.yingchui.interconnect.pad"
    private static let account = "host-credentials-v2"
    private let store: HostTrustStore
    private var loaded: Bool

    init(store: HostTrustStore? = nil, loaded: Bool = false) {
        self.store = store ?? HostTrustStore(
            read: { try SecureStore.data(service: Self.service, account: Self.account) },
            write: { try SecureStore.set($0, service: Self.service, account: Self.account) }
        )
        self.loaded = loaded
    }

    func load() throws {
        if try !store.load() {
            let legacy = try legacyRecords()
            try store.migrate(tokens: legacy.tokens, pins: legacy.pins)
        }
        try removeLegacyRecords()
        loaded = true
    }

    func credential(for hostID: String) -> HostCredential? {
        guard loaded else { return nil }
        return store.credential(for: hostID)
    }

    func save(_ credential: HostCredential, for hostID: String) throws {
        guard loaded else { throw HostTrustError.incompleteCredential }
        try store.save(credential, for: hostID)
    }

    func legacyCredential(matching fingerprint: String) throws -> HostCredential? {
        guard loaded else { throw HostTrustError.incompleteCredential }
        return try store.legacyCredential(matching: fingerprint)
    }

    func bindLegacyCredential(_ credential: HostCredential, to hostID: String) throws {
        guard loaded else { throw HostTrustError.incompleteCredential }
        try store.bindLegacyCredential(credential, to: hostID)
    }

    func remove(hostID: String) throws {
        if !loaded {
            if try !store.load() {
                var legacy = try legacyRecords()
                legacy.tokens.removeValue(forKey: hostID)
                legacy.pins.removeValue(forKey: hostID)
                try store.migrate(tokens: legacy.tokens, pins: legacy.pins)
            }
        }
        try store.remove(hostID: hostID)
        try removeLegacyRecords()
        loaded = true
    }

    func removeAll() throws {
        try store.removeAll()
        try removeLegacyRecords()
        loaded = true
    }

    private func legacyRecords() throws -> (tokens: [String: String], pins: [String: String]) {
        let tokens = try SecureDictionaryStore.load(
            service: Self.service, account: "trusted-session-tokens-v1",
            legacyDefaultsKey: "YingchuiPadSessionTokens"
        )
        let pins = try SecureDictionaryStore.load(
            service: Self.service, account: "certificate-pins-v1",
            legacyDefaultsKey: "YingchuiPadCertificatePins"
        )
        return (tokens, pins)
    }

    private func removeLegacyRecords() throws {
        try SecureStore.remove(service: Self.service, account: "trusted-session-tokens-v1")
        try SecureStore.remove(service: Self.service, account: "certificate-pins-v1")
        UserDefaults.standard.removeObject(forKey: "YingchuiPadSessionTokens")
        UserDefaults.standard.removeObject(forKey: "YingchuiPadCertificatePins")
    }
}
