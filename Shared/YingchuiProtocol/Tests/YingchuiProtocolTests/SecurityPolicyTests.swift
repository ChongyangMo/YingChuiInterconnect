import Foundation
import Testing
@testable import YingchuiProtocol

@Test func pairingBudgetSurvivesCodeRotationAndConnectionChanges() throws {
    var policy = PairingAttemptPolicy(now: 0)
    for time in 0..<5 { try policy.consumeAttempt(at: Double(time)) }
    policy.rotateCode(at: 5)
    #expect(throws: PairingAttemptError.rateLimited) { try policy.consumeAttempt(at: 6) }
    try policy.consumeAttempt(at: 60)
}

@Test func expiredCodeCannotPairUntilItIsRotated() throws {
    var policy = PairingAttemptPolicy(now: 0)
    #expect(throws: PairingAttemptError.expired) { try policy.consumeAttempt(at: 300) }
    policy.rotateCode(at: 301)
    try policy.consumeAttempt(at: 301)
}

private final class TestCredentialStorage {
    var data: Data?
    var rejectWrites = false
    enum Failure: Error { case write }
    func write(_ data: Data) throws {
        if rejectWrites { throw Failure.write }
        self.data = data
    }
    func store() -> HostTrustStore {
        HostTrustStore(read: { self.data }, write: { try self.write($0) })
    }
}

@Test func credentialWriteFailureKeepsCompleteOldRecordOnRestart() throws {
    let storage = TestCredentialStorage()
    let store = storage.store()
    let host = UUID().uuidString
    let pin = Data(repeating: 1, count: 32).base64EncodedString()
    let old = try HostCredential(token: Data(repeating: 2, count: 32).base64EncodedString(), certificateFingerprint: pin)
    let next = try HostCredential(token: Data(repeating: 3, count: 32).base64EncodedString(), certificateFingerprint: pin)
    try store.save(old, for: host)
    storage.rejectWrites = true
    #expect(throws: TestCredentialStorage.Failure.self) { try store.save(next, for: host) }
    #expect(store.credential(for: host) == old)
    let restarted = storage.store()
    #expect(try restarted.load())
    #expect(restarted.credential(for: host) == old)
}

@Test func partialLegacyCredentialIsRejectedWithoutWriting() throws {
    let storage = TestCredentialStorage()
    let store = storage.store()
    #expect(throws: HostTrustError.self) {
        try store.migrate(tokens: [UUID().uuidString: Data(repeating: 1, count: 32).base64EncodedString()], pins: [:])
    }
    #expect(storage.data == nil)
}

@Test func removedCredentialCannotReappearAfterRestart() throws {
    let storage = TestCredentialStorage()
    let store = storage.store()
    let host = UUID().uuidString
    let value = Data(repeating: 1, count: 32).base64EncodedString()
    try store.migrate(tokens: [host: value], pins: [host: value])
    try store.remove(hostID: host)
    let restarted = storage.store()
    #expect(try restarted.load())
    #expect(restarted.credential(for: host) == nil)
}

@Test func incompleteSerializedCredentialFailsClosed() throws {
    let store = HostTrustStore(read: { Data("{\"\(UUID().uuidString)\":{\"token\":\"bad\",\"certificateFingerprint\":\"\"}}".utf8) }, write: { _ in })
    #expect(throws: HostTrustError.self) { _ = try store.load() }
}

@Test func configurationWithoutPlaybackDoesNotResetRecoveryBudget() {
    var policy = StreamRecoveryPolicy()
    #expect(policy.nextDelaySeconds() == 1)
    #expect(policy.nextDelaySeconds() == 2)
    #expect(policy.nextDelaySeconds() == 4)
    #expect(policy.nextDelaySeconds() == nil)
}

@Test func onlySustainedDecodedProgressResetsRecoveryBudget() {
    var policy = StreamRecoveryPolicy()
    #expect(policy.nextDelaySeconds() == 1)
    for _ in 0..<4 { policy.recordHealthyInterval() }
    policy.recordStalledInterval()
    policy.recordHealthyInterval()
    #expect(policy.nextDelaySeconds() == 2)
    for _ in 0..<5 { policy.recordHealthyInterval() }
    #expect(policy.nextDelaySeconds() == 1)
}

@Test func statisticsRejectOverflowAndDoNotPoisonNextSample() throws {
    var tracker = StreamStatisticsTracker()
    #expect(try tracker.lossRate(decoded: 100, dropped: 0) == nil)
    #expect(throws: StreamStatisticsError.self) { _ = try tracker.lossRate(decoded: UInt64.max, dropped: 1) }
    #expect(try tracker.lossRate(decoded: 160, dropped: 0) == 0)
}

@Test func explicitResetCanReplaceUnreadableLegacyStateWithoutResurrection() throws {
    let storage = TestCredentialStorage()
    storage.data = Data("损坏的历史凭据".utf8)
    let store = storage.store()
    #expect(throws: (any Error).self) { _ = try store.load() }
    try store.removeAll()
    let restarted = storage.store()
    #expect(try restarted.load())
    #expect(try JSONDecoder().decode([String: HostCredential].self, from: #require(storage.data)).isEmpty)
}
