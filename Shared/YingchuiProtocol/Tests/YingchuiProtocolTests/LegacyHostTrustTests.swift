import Foundation
import Testing
@testable import YingchuiProtocol

private final class LegacyStorage {
    var data: Data?
    var rejectWrites = false
    enum Failure: Error { case write }
    func store() -> HostTrustStore {
        HostTrustStore(read: { self.data }, write: {
            if self.rejectWrites { throw Failure.write }
            self.data = $0
        })
    }
}

private func credential(_ token: UInt8 = 1, pin: UInt8 = 2) throws -> HostCredential {
    try HostCredential(token: Data(repeating: token, count: 32).base64EncodedString(),
                       certificateFingerprint: Data(repeating: pin, count: 32).base64EncodedString())
}

@Test func namedLegacyRecordsLoadWithoutAuthorizingNamesOrNewUUIDs() throws {
    let storage = LegacyStorage(), value = try credential()
    let store = storage.store()
    try store.migrate(tokens: ["旧版 Mac.local": value.token], pins: ["旧版 Mac.local": value.certificateFingerprint])
    let reopened = storage.store()
    #expect(try reopened.load())
    #expect(reopened.credential(for: "旧版 Mac.local") == nil)
    #expect(reopened.credential(for: UUID().uuidString) == nil)
    #expect(try reopened.legacyCredential(matching: value.certificateFingerprint) == value)
    #expect(try reopened.legacyCredential(matching: credential(pin: 3).certificateFingerprint) == nil)
}

@Test func verifiedLegacyBindingPreservesOtherHostsAndPersistsAtomically() throws {
    let storage = LegacyStorage(), value = try credential(), other = try credential(3, pin: 4)
    let existingID = UUID().uuidString, newID = UUID().uuidString
    storage.data = try JSONEncoder().encode(["旧名称": value, "旧名称 (2)": value, "另一台 Mac": other, existingID: other])
    let store = storage.store()
    #expect(try store.load())
    try store.bindLegacyCredential(value, to: newID)
    let reopened = storage.store()
    #expect(try reopened.load())
    #expect(reopened.credential(for: newID) == value)
    #expect(reopened.credential(for: existingID) == other)
    #expect(try reopened.legacyCredential(matching: value.certificateFingerprint) == nil)
    #expect(try reopened.legacyCredential(matching: other.certificateFingerprint) == other)
}

@Test func failedLegacyBindingPreservesOriginalBytesAndMemory() throws {
    let storage = LegacyStorage(), value = try credential(), id = UUID().uuidString
    storage.data = try JSONEncoder().encode(["旧名称": value])
    let before = storage.data, store = storage.store()
    #expect(try store.load())
    storage.rejectWrites = true
    #expect(throws: LegacyStorage.Failure.self) { try store.bindLegacyCredential(value, to: id) }
    #expect(storage.data == before)
    #expect(store.credential(for: id) == nil)
    #expect(try store.legacyCredential(matching: value.certificateFingerprint) == value)
}

@Test func legacyBindingRejectsInventedCredentialAndInvalidDestination() throws {
    let storage = LegacyStorage(), value = try credential()
    storage.data = try JSONEncoder().encode(["旧名称": value])
    let store = storage.store(), before = storage.data
    #expect(try store.load())
    #expect(throws: HostTrustError.self) { try store.bindLegacyCredential(credential(9), to: UUID().uuidString) }
    #expect(throws: HostTrustError.self) { try store.bindLegacyCredential(value, to: "另一个名称") }
    #expect(storage.data == before)
}

@Test func conflictingTokensForOneLegacyCertificateFailExplicitly() throws {
    let storage = LegacyStorage(), first = try credential(), second = try credential(3)
    storage.data = try JSONEncoder().encode(["旧名称": first, "旧名称 (2)": second])
    let store = storage.store(), before = storage.data
    #expect(try store.load())
    #expect(throws: HostTrustError.self) { _ = try store.legacyCredential(matching: first.certificateFingerprint) }
    #expect(storage.data == before)
}

@Test func emptyLegacyKeyAndInvalidCredentialStillFailWithoutWriting() throws {
    let storage = LegacyStorage(), value = try credential()
    storage.data = try JSONEncoder().encode(["": value])
    let before = storage.data, store = storage.store()
    #expect(throws: HostTrustError.self) { _ = try store.load() }
    #expect(throws: HostTrustError.self) { try store.migrate(tokens: ["旧名称": "损坏"], pins: ["旧名称": value.certificateFingerprint]) }
    #expect(storage.data == before)
}

@Test func forgettingUUIDAlsoRemovesItsLegacyAliasesWithoutResurrection() throws {
    let storage = LegacyStorage(), value = try credential(), other = try credential(4, pin: 5)
    let id = UUID().uuidString
    storage.data = try JSONEncoder().encode([id: value, "旧名称": value, "另一台": other])
    let store = storage.store()
    #expect(try store.load())
    try store.remove(hostID: id)
    let reopened = storage.store()
    #expect(try reopened.load())
    #expect(reopened.credential(for: id) == nil)
    #expect(try reopened.legacyCredential(matching: value.certificateFingerprint) == nil)
    #expect(try reopened.legacyCredential(matching: other.certificateFingerprint) == other)
}

@Test func explicitNewPairingReplacesAliasesForOnlyTheVerifiedCertificate() throws {
    let storage = LegacyStorage(), old = try credential(), fresh = try credential(7), other = try credential(4, pin: 5)
    let id = UUID().uuidString
    storage.data = try JSONEncoder().encode(["旧名称": old, "另一台": other])
    let store = storage.store()
    #expect(try store.load())
    try store.save(fresh, for: id)
    #expect(store.credential(for: id) == fresh)
    #expect(try store.legacyCredential(matching: old.certificateFingerprint) == nil)
    #expect(try store.legacyCredential(matching: other.certificateFingerprint) == other)
}
