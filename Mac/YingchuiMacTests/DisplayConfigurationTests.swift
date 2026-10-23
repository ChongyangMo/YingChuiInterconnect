import CoreGraphics
import XCTest
@testable import YingchuiMac

private final class RecordingDisplayDriver: DisplayConfigurationApplying {
    enum Failure: Error { case commit }
    var calls: [String] = []
    var failCommit = false
    func begin() throws { calls.append("开始") }
    func setMirror(_ id: CGDirectDisplayID, source: CGDirectDisplayID) throws { calls.append("镜像 \(id) \(source)") }
    func setMode(_ id: CGDirectDisplayID, mode: CGDisplayMode) throws { calls.append("模式 \(id)") }
    func setOrigin(_ id: CGDirectDisplayID, origin: CGPoint) throws { calls.append("位置 \(id)") }
    func commit() throws {
        calls.append("提交")
        if failCommit { throw Failure.commit }
    }
    func cancel() { calls.append("取消") }
}

final class DisplayConfigurationTests: XCTestCase {
    func testRestoresOriginalMirrorGraphAfterModesAndOrigins() throws {
        let mode = try XCTUnwrap(CGDisplayCopyDisplayMode(CGMainDisplayID()))
        let snapshot = DisplayConfigurationSnapshot(entries: [
            .init(id: 10, mirrorSource: 0, mode: mode, origin: .zero),
            .init(id: 11, mirrorSource: 10, mode: mode, origin: .zero)
        ])
        let driver = RecordingDisplayDriver()
        try snapshot.restore(using: driver)
        XCTAssertEqual(driver.calls, ["开始", "镜像 10 0", "镜像 11 0", "模式 10", "位置 10",
            "模式 11", "位置 11", "镜像 11 10", "提交"])
    }

    func testRestoreCommitFailureIsReportedAndTransactionCancelled() throws {
        let mode = try XCTUnwrap(CGDisplayCopyDisplayMode(CGMainDisplayID()))
        let snapshot = DisplayConfigurationSnapshot(entries: [.init(id: 10, mirrorSource: 0, mode: mode, origin: .zero)])
        let driver = RecordingDisplayDriver()
        driver.failCommit = true
        XCTAssertThrowsError(try snapshot.restore(using: driver))
        XCTAssertEqual(driver.calls.suffix(2), ["提交", "取消"])
    }

    func testCurrentDisplayConfigurationCanBeCapturedWithoutMutation() throws {
        let snapshot = try DisplayConfigurationSnapshot.capture()
        XCTAssertFalse(snapshot.entries.isEmpty)
        XCTAssertTrue(snapshot.entries.allSatisfy { $0.id != kCGNullDirectDisplay })
    }
}

extension DisplayConfigurationTests {
    func testCurrentSystemProvidesRequiredVirtualDisplayMethods() {
        XCTAssertTrue(YCVirtualDisplayBridge.isSupported, "当前系统缺少 Retina 虚拟显示器所需接口")
    }
}
