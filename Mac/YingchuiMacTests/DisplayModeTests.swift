import ScreenCaptureKit
import CoreGraphics
import XCTest
import YingchuiProtocol
@testable import YingchuiMac

final class DisplayModeTests: XCTestCase {
    func testArrangementSurroundsAllPhysicalDisplaysIncludingNegativeOrigins() throws {
        let bounds = [CGRect(x: -1920, y: 0, width: 1920, height: 1080), CGRect(x: 0, y: -900, width: 1440, height: 900)]
        let size = CGSize(width: 1112, height: 834)
        XCTAssertEqual(try MacDisplayLayout.origin(size: size, physicalBounds: bounds, placement: .left), CGPoint(x: -3032, y: 0))
        XCTAssertEqual(try MacDisplayLayout.origin(size: size, physicalBounds: bounds, placement: .right), CGPoint(x: 1440, y: -900))
        XCTAssertEqual(try MacDisplayLayout.origin(size: size, physicalBounds: bounds, placement: .above), CGPoint(x: 0, y: -1734))
        XCTAssertEqual(try MacDisplayLayout.origin(size: size, physicalBounds: bounds, placement: .below), CGPoint(x: -1920, y: 1080))
        XCTAssertThrowsError(try MacDisplayLayout.origin(size: .zero, physicalBounds: bounds, placement: .right))
    }

    func testRealMirrorExtensionSwitchesPreserveVirtualIDAndRestorePhysicalMode() async throws {
        // 创建真实系统显示器作为外接屏替身；不把它当作 HDMI 实物测试。
        let store = DisplayRecoveryStore(url: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "display.json"))
        let manager = MacVirtualDisplayManager(recoveryStore: store)
        let external = try YCVirtualDisplayBridge(pixelWidth: 1280, pixelHeight: 800, refreshRate: 60)
        defer { manager.deactivate(); external.invalidate() }
        try await waitUntil { CGDisplayCopyDisplayMode(external.displayID)?.pixelWidth == 1280 }
        let baseline = try XCTUnwrap(CGDisplayCopyDisplayMode(external.displayID))
        let pixels = StreamDimensions(width: 1920, height: 1080)
        let initial = try manager.activate(requestedPixels: pixels, mirroring: external.displayID, refreshRate: 60)
        try await waitUntil { CGDisplayMirrorsDisplay(external.displayID) == initial.displayID }
        XCTAssertEqual(try manager.confirmedState(placement: .right).mode, .mirror)
        try await captureFrame(display: initial.displayID)
        for placement in RemoteDisplayPlacement.allCases {
            let extended = try manager.activate(requestedPixels: pixels, mirroring: nil, refreshRate: 60)
            XCTAssertEqual(extended.displayID, initial.displayID)
            try await waitUntil { CGDisplayMirrorsDisplay(external.displayID) == 0 }
            try manager.arrange(placement: placement)
            try await waitUntil { (try manager.confirmedState(placement: placement)).mode == .extended }
            XCTAssertEqual(CGDisplayCopyDisplayMode(external.displayID)?.pixelWidth, baseline.pixelWidth)
            XCTAssertEqual(CGDisplayCopyDisplayMode(external.displayID)?.pixelHeight, baseline.pixelHeight)
            XCTAssertFalse(store.exists)
            if placement == .left { try await captureFrame(display: extended.displayID) }
            let mirror = try manager.activate(requestedPixels: pixels, mirroring: external.displayID, refreshRate: 60)
            XCTAssertEqual(mirror.displayID, initial.displayID)
            try await waitUntil { CGDisplayMirrorsDisplay(external.displayID) == initial.displayID }
            let record = try store.load()
            XCTAssertFalse(record.entries.contains { $0.displayUUID == (try? DisplayRecoveryRecord.uuid(initial.displayID)) })
            XCTAssertEqual(try manager.confirmedState(placement: placement).mode, .mirror)
        }
        try manager.restoreSavedConfiguration()
        XCTAssertFalse(store.exists)
        XCTAssertNil(manager.activeDisplayID)
        try await waitUntil { CGDisplayMirrorsDisplay(external.displayID) == 0 }
        XCTAssertEqual(CGDisplayCopyDisplayMode(external.displayID)?.pixelWidth, baseline.pixelWidth)
    }

    private func captureFrame(display: CGDirectDisplayID) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw NSError(domain: "显示模式测试", code: 1, userInfo: [NSLocalizedDescriptionKey: "测试进程没有已有录屏权限"])
        }
        let content = try await SCShareableContent.current
        let source = try XCTUnwrap(content.displays.first { $0.displayID == display })
        let configuration = SCStreamConfiguration()
        configuration.width = 1920
        configuration.height = 1080
        let frame = expectation(description: "显示模式收到真实画面")
        let output = HeadlessCaptureOutput { width, height in
            XCTAssertEqual(width, 1920)
            XCTAssertEqual(height, 1080)
            frame.fulfill()
        }
        let capture = SCStream(filter: SCContentFilter(display: source, excludingWindows: []), configuration: configuration, delegate: nil)
        try capture.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "显示模式采集测试"))
        try await capture.startCapture()
        await fulfillment(of: [frame], timeout: 8)
        try await capture.stopCapture()
    }

    private func waitUntil(_ predicate: () throws -> Bool) async throws {
        for _ in 0..<80 {
            if try predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("显示模式应用超时")
        throw MacDisplayLayout.LayoutError.inconsistentState
    }
}
