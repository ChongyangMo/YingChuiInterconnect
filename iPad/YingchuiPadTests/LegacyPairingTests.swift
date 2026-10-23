import Foundation
import XCTest
import YingchuiProtocol
@testable import YingchuiPad

final class LegacyPairingTests: XCTestCase, @unchecked Sendable {
    @MainActor
    private func fixture(rejectWrites: Bool = false) throws -> (PadConnectionModel, HostTrustStore, HostCredential) {
        enum Failure: Error { case write }
        let value = try HostCredential(token: Data(repeating: 1, count: 32).base64EncodedString(),
                                       certificateFingerprint: Data(repeating: 2, count: 32).base64EncodedString())
        let data = SynchronizedValue(try JSONEncoder().encode(["旧版 Mac.local": value]))
        let store = HostTrustStore(read: { data.value }, write: {
            if rejectWrites { throw Failure.write }
            data.set($0)
        })
        XCTAssertTrue(try store.load())
        let model = PadConnectionModel(startServices: false, trustStore: PadTrustStore(store: store, loaded: true))
        model.connectedHostKey = UUID().uuidString
        model.pendingHelloID = UUID()
        model.pendingCertificateFingerprint = value.certificateFingerprint
        model.pendingLegacyCredential = value
        return (model, store, value)
    }

    @MainActor
    private func drain(_ model: PadConnectionModel) async {
        await withCheckedContinuation { continuation in
            model.networkQueue.async { Task { @MainActor in continuation.resume() } }
        }
    }

    @MainActor
    func testAcceptedLegacyHelloBindsUUIDBeforeEnablingControl() async throws {
        let (model, store, value) = try fixture()
        let id = try XCTUnwrap(model.connectedHostKey)
        model.handleHello(WireMessage(id: try XCTUnwrap(model.pendingHelloID), kind: .hello, hostID: id, accepted: true))
        await drain(model)
        XCTAssertTrue(model.isPaired)
        XCTAssertEqual(store.credential(for: id), value)
        XCTAssertNil(try store.legacyCredential(matching: value.certificateFingerprint))
    }

    @MainActor
    func testRejectedLegacyTokenKeepsRecordsAndShowsPairing() async throws {
        let (model, store, value) = try fixture()
        let id = try XCTUnwrap(model.connectedHostKey)
        model.handleHello(WireMessage(id: try XCTUnwrap(model.pendingHelloID), kind: .hello, hostID: id, accepted: false))
        await drain(model)
        XCTAssertFalse(model.isPaired)
        XCTAssertNil(store.credential(for: id))
        XCTAssertEqual(try store.legacyCredential(matching: value.certificateFingerprint), value)
        XCTAssertEqual(model.statusText, "等待配对")
    }

    @MainActor
    func testMismatchedLegacyHelloCannotBindOrEnableControl() async throws {
        for mismatch in ["request", "host", "certificate"] {
            let (model, store, value) = try fixture()
            let id = try XCTUnwrap(model.connectedHostKey)
            if mismatch == "certificate" { model.pendingCertificateFingerprint = Data(repeating: 9, count: 32).base64EncodedString() }
            model.handleHello(WireMessage(id: mismatch == "request" ? UUID() : try XCTUnwrap(model.pendingHelloID),
                kind: .hello, hostID: mismatch == "host" ? UUID().uuidString : id, accepted: true))
            await drain(model)
            XCTAssertFalse(model.isPaired, mismatch)
            XCTAssertNil(store.credential(for: id), mismatch)
            XCTAssertEqual(try store.legacyCredential(matching: value.certificateFingerprint), value)
        }
    }

    @MainActor
    func testFailedMigrationWriteCannotEnableControl() async throws {
        let (model, store, value) = try fixture(rejectWrites: true)
        let id = try XCTUnwrap(model.connectedHostKey)
        model.handleHello(WireMessage(id: try XCTUnwrap(model.pendingHelloID), kind: .hello, hostID: id, accepted: true))
        await drain(model)
        XCTAssertFalse(model.isPaired)
        XCTAssertNotNil(model.credentialStoreErrorText)
        XCTAssertNil(store.credential(for: id))
        XCTAssertEqual(try store.legacyCredential(matching: value.certificateFingerprint), value)
    }
}
