import CoreGraphics
import Foundation
import XCTest
@testable import YingchuiMac

final class DisplayRecoveryRestorerTests: XCTestCase {
    func testCaptureRecoveryOnlyAppliesOnceNearDisplayChange() {
        var window = DisplayCaptureRecoveryWindow()
        XCTAssertFalse(window.consume(now: 0))
        window.displayChanged(now: 1)
        XCTAssertTrue(window.consume(now: 2))
        XCTAssertFalse(window.consume(now: 3))
        window.displayChanged(now: 4)
        XCTAssertFalse(window.consume(now: 13), "过期拔线不能触发无关的采集重启")
        window.displayChanged(now: 14)
        window.reset()
        XCTAssertFalse(window.consume(now: 15))
    }

    func testSerialNumberSurvivesConnectionUnitChangeButAnonymousScreensDoNot() {
        XCTAssertEqual(DisplayRecoveryRecord.canonicalIdentifier("12462-3879-51282-0"),
                       DisplayRecoveryRecord.canonicalIdentifier("12462-3879-51282-4"))
        XCTAssertNotEqual(DisplayRecoveryRecord.canonicalIdentifier("12462-3879-0-0"),
                          DisplayRecoveryRecord.canonicalIdentifier("12462-3879-0-4"))
    }

    private func record() throws -> DisplayRecoveryRecord {
        try DisplayRecoveryRecord(snapshot: DisplayConfigurationSnapshot.capture())
    }

    private func store() -> DisplayRecoveryStore {
        DisplayRecoveryStore(url: FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString).appending(path: "recovery.json"))
    }

    func testAbsentHardwarePreservesRecordThenReplugRestoresExactlyOnce() throws {
        let store = store(), record = try record()
        try store.save(record)
        let original = try Data(contentsOf: store.url)
        var available: Set<String> = []
        var calls = 0
        let restorer = DisplayRecoveryRestorer(store: store, onlineIdentifiers: { available }, apply: {
            XCTAssertEqual($0, record)
            calls += 1
        })
        XCTAssertEqual(try restorer.restoreAvailable(), .waitingForHardware)
        XCTAssertEqual(try Data(contentsOf: store.url), original)
        XCTAssertEqual(calls, 0)
        available = try record.requiredDisplayUUIDs()
        XCTAssertEqual(try restorer.restoreAvailable(), .restored)
        XCTAssertFalse(store.exists)
        XCTAssertEqual(try restorer.restoreAvailable(), .nothingToRestore)
        XCTAssertEqual(calls, 1)
    }

    func testApplyFailurePreservesRecordAndPropagatesError() throws {
        enum Failure: Error { case apply }
        let store = store(), record = try record()
        try store.save(record)
        let restorer = DisplayRecoveryRestorer(store: store,
            onlineIdentifiers: { try record.requiredDisplayUUIDs() }, apply: { _ in throw Failure.apply })
        XCTAssertThrowsError(try restorer.restoreAvailable())
        XCTAssertEqual(try store.load(), record)
    }

    func testEnumerationFailureDoesNotBecomeHeadlessMode() throws {
        enum Failure: Error { case enumerate }
        let store = store(), record = try record()
        try store.save(record)
        let restorer = DisplayRecoveryRestorer(store: store, onlineIdentifiers: { throw Failure.enumerate },
                                               apply: { _ in XCTFail("枚举失败不可修改显示配置") })
        XCTAssertThrowsError(try restorer.restoreAvailable())
        XCTAssertEqual(try store.load(), record)
    }

    func testInvalidRecordFailsEvenWhenAllHardwareIsAbsent() throws {
        let store = store()
        let invalid = try JSONDecoder().decode(DisplayRecoveryRecord.self, from: Data("{\"entries\":[]}".utf8))
        try store.save(invalid)
        let restorer = DisplayRecoveryRestorer(store: store, onlineIdentifiers: { [] },
                                               apply: { _ in XCTFail("无效记录不可执行") })
        XCTAssertThrowsError(try restorer.restoreAvailable())
        XCTAssertTrue(store.exists)
    }

    func testNewManagerAutomaticallyRestoresRealSavedConfiguration() async throws {
        let display = try YCVirtualDisplayBridge(pixelWidth: 1280, pixelHeight: 800, refreshRate: 60)
        defer { display.invalidate() }
        for _ in 0..<60 {
            if CGDisplayCopyDisplayMode(display.displayID)?.pixelWidth == 1280 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let snapshot = try DisplayConfigurationSnapshot.capture()
        let entry = try XCTUnwrap(snapshot.entries.first { $0.id == display.displayID })
        let store = store()
        try store.save(DisplayRecoveryRecord(snapshot: DisplayConfigurationSnapshot(entries: [entry])))
        let manager = MacVirtualDisplayManager(recoveryStore: store)
        try manager.reconcileDisplays()
        XCTAssertFalse(store.exists)
        XCTAssertNil(manager.activeDisplayID)
    }
}
