import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import XCTest
import YingchuiProtocol
@testable import YingchuiMac

final class HeadlessDisplayTests: XCTestCase {
    func testStandaloneVirtualDesktopProducesRealScreenCaptureFrames() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.permissionRequired
        }
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "recovery.json")
        let manager = MacVirtualDisplayManager(recoveryStore: DisplayRecoveryStore(url: url))
        let session = try manager.activate(requestedPixels: .init(width: 1280, height: 720), mirroring: nil, refreshRate: 60)
        defer { manager.deactivate() }
        var display: SCDisplay?
        for _ in 0..<60 {
            display = try await SCShareableContent.current.displays.first { $0.displayID == session.displayID }
            if display != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let source = try XCTUnwrap(display, "独立虚拟屏必须能被系统采集")
        let configuration = SCStreamConfiguration()
        configuration.width = 1280
        configuration.height = 720
        configuration.capturesAudio = false
        let firstFrame = expectation(description: "收到独立虚拟桌面的真实画面")
        let output = HeadlessCaptureOutput { width, height in
            XCTAssertEqual(width, 1280)
            XCTAssertEqual(height, 720)
            firstFrame.fulfill()
        }
        let capture = SCStream(filter: SCContentFilter(display: source, excludingWindows: []),
                               configuration: configuration, delegate: nil)
        try capture.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "独立桌面采集测试"))
        try await capture.startCapture()
        await fulfillment(of: [firstFrame], timeout: 8)
        try await capture.stopCapture()
    }

    func testZeroDisplaysSelectsStandaloneDesktop() throws {
        XCTAssertNil(try MacDisplayRouting.mirrorTarget(selected: nil, online: [], ownedVirtualDisplay: nil))
        XCTAssertNil(try MacDisplayRouting.mirrorTarget(selected: 1, online: [], ownedVirtualDisplay: nil))
    }

    func testExistingOwnedVirtualDisplayIsNotUsedAsMirrorTarget() throws {
        XCTAssertNil(try MacDisplayRouting.mirrorTarget(selected: nil, online: [92], ownedVirtualDisplay: 92))
        XCTAssertEqual(try MacDisplayRouting.mirrorTarget(selected: 1, online: [1, 92], ownedVirtualDisplay: 92), 1)
    }

    func testInvalidSelectionDoesNotSilentlyReplaceAnOnlineDisplay() {
        XCTAssertThrowsError(try MacDisplayRouting.mirrorTarget(selected: 2, online: [1], ownedVirtualDisplay: nil))
        XCTAssertThrowsError(try MacDisplayRouting.mirrorTarget(selected: nil, online: [1], ownedVirtualDisplay: nil))
    }

    func testStandaloneDisplayCreatesReusesAndReleasesWithoutRecoveryFile() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "recovery.json")
        let store = DisplayRecoveryStore(url: url)
        let manager = MacVirtualDisplayManager(recoveryStore: store)
        let original = try DisplayConfigurationSnapshot.capture()
        let pixels = StreamDimensions(width: 1280, height: 720)
        let session = try manager.activate(requestedPixels: pixels, mirroring: nil, refreshRate: 60)
        defer { manager.deactivate() }
        XCTAssertNil(session.physicalDisplayID)
        XCTAssertNil(manager.activePhysicalDisplayID)
        XCTAssertFalse(store.exists, "独立桌面没有物理镜像恢复记录")
        for _ in 0..<60 {
            if MacScreenStreamer.activePixelDimensions(for: session.displayID) == pixels { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(MacScreenStreamer.activePixelDimensions(for: session.displayID), pixels)
        XCTAssertEqual(CGDisplayMirrorsDisplay(session.displayID), kCGNullDirectDisplay)
        for entry in original.entries {
            XCTAssertEqual(CGDisplayMirrorsDisplay(entry.id), entry.mirrorSource)
            XCTAssertEqual(CGDisplayCopyDisplayMode(entry.id)?.pixelWidth, entry.mode.pixelWidth)
            XCTAssertEqual(CGDisplayCopyDisplayMode(entry.id)?.pixelHeight, entry.mode.pixelHeight)
        }
        let reused = try manager.activate(requestedPixels: pixels, mirroring: nil, refreshRate: 60)
        XCTAssertEqual(reused.displayID, session.displayID)
        try manager.restoreSavedConfiguration()
        XCTAssertNil(manager.activeDisplayID)
        XCTAssertFalse(store.exists)
    }

    func testStandaloneModeDoesNotIgnorePendingPhysicalRecovery() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = folder.appending(path: "recovery.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = Data("待恢复的原始记录".utf8)
        try data.write(to: url)
        defer {
            do { try FileManager.default.removeItem(at: folder) }
            catch { XCTFail("清理测试文件失败：\(error.localizedDescription)") }
        }
        let manager = MacVirtualDisplayManager(recoveryStore: DisplayRecoveryStore(url: url))
        XCTAssertThrowsError(try manager.activate(requestedPixels: .init(width: 1280, height: 720), mirroring: nil, refreshRate: 60))
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertNil(manager.activeDisplayID)
    }
}

private enum CaptureError: LocalizedError {
    case permissionRequired
    var errorDescription: String? { "当前测试进程没有已有的屏幕录制授权，不请求新权限" }
}

final class HeadlessCaptureOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let received = SynchronizedValue(false)
    private let onFrame: @Sendable (Int, Int) -> Void
    init(onFrame: @escaping @Sendable (Int, Int) -> Void) { self.onFrame = onFrame }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, let image = sampleBuffer.imageBuffer,
              received.mutate({ value in
                  guard !value else { return false }
                  value = true
                  return true
              }) else { return }
        onFrame(CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image))
    }
}
