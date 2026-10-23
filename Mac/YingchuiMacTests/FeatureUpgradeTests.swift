import AVFoundation
import CoreGraphics
import XCTest
import Network
import YingchuiProtocol
@testable import YingchuiMac

final class FeatureUpgradeTests: XCTestCase, @unchecked Sendable {
    func testRecoveryRecordSurvivesNewStoreInstanceAndResolvesCurrentHardware() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("display.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let record = try DisplayRecoveryRecord(snapshot: DisplayConfigurationSnapshot.capture())
        try DisplayRecoveryStore(url: url).save(record)
        let reopened = DisplayRecoveryStore(url: url)
        XCTAssertEqual(try reopened.load(), record)
        XCTAssertEqual(try reopened.load().resolve().entries.count, record.entries.count)
        try reopened.clear()
        XCTAssertFalse(reopened.exists)
    }

    func testCorruptRecoveryRecordIsPreservedAndReported() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("invalid".utf8).write(to: url)
        let store = DisplayRecoveryStore(url: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertTrue(store.exists)
    }

    func testAudioPCMConversionPreservesStereoAndClampsSamples() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        buffer.frameLength = 2
        let planes = try XCTUnwrap(buffer.floatChannelData)
        planes[0][0] = 1; planes[1][0] = -1
        planes[0][1] = 0; planes[1][1] = 2
        XCTAssertEqual(try MacAudioSender.interleavedPCM(buffer), Data([255,127,1,128,0,0,255,127]))
        planes[0][0] = .nan
        XCTAssertThrowsError(try MacAudioSender.interleavedPCM(buffer))
    }

    func testOnlyOneAuthorizedSessionCanControlMac() {
        let host = MacHostModel(startServices: false)
        func session() -> HostPeerSession {
            let value = HostPeerSession(connection: NWConnection(host: .ipv4(.loopback), port: 9, using: .tcp),
                onMessage: { _, _ in }, onClosed: { _ in }, onStatus: { _ in })
            value.isAuthorized = true
            host.sessions[value.id] = value
            return value
        }
        let first = session(), second = session()
        XCTAssertTrue(host.claimController(first))
        XCTAssertFalse(host.claimController(second))
        host.remove(first)
        XCTAssertTrue(host.claimController(second))
    }
}

extension FeatureUpgradeTests {
    @MainActor
    func testRevokingOneDevicePreservesOtherCredentials() async {
        let host = MacHostModel(startServices: false)
        let saved = SynchronizedValue<[String: String]>([:])
        host.trustedDeviceTokens = ["first": "one", "second": "two"]
        host.trustedDeviceWriter = { saved.set($0) }
        host.revokeDevice("first")
        await withCheckedContinuation { continuation in host.networkQueue.async { continuation.resume() } }
        XCTAssertEqual(host.trustedDeviceTokens, ["second": "two"])
        XCTAssertEqual(saved.value, ["second": "two"])
    }

    @MainActor
    func testFailedRevocationDoesNotRemoveAuthorization() async {
        enum Failure: Error { case storage }
        let host = MacHostModel(startServices: false)
        host.trustedDeviceTokens = ["first": "one"]
        host.trustedDeviceWriter = { _ in throw Failure.storage }
        host.revokeDevice("first")
        await withCheckedContinuation { continuation in host.networkQueue.async { continuation.resume() } }
        XCTAssertEqual(host.trustedDeviceTokens, ["first": "one"])
    }
}
