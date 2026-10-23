import CoreGraphics
import Foundation
import ScreenCaptureKit
import XCTest
@testable import YingchuiMac

final class DisplayHotplugTests: XCTestCase {
    func testRemovingMirroredDisplayKeepsVirtualDesktopAndRestoresAfterReattachment() async throws {
        // 用真实可移除虚拟屏模拟外接屏，触发系统级显示器移除；不冒充 HDMI 实物拔线验收。
        let baseline = try DisplayConfigurationSnapshot.capture()
        let store = DisplayRecoveryStore(url: FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString).appending(path: "recovery.json"))
        let manager = MacVirtualDisplayManager(recoveryStore: store)
        var external: YCVirtualDisplayBridge? = try autoreleasepool { try YCVirtualDisplayBridge(pixelWidth: 1280, pixelHeight: 800, refreshRate: 60) }
        var baselineRestored = false
        defer {
            if !baselineRestored {
                manager.deactivate()
                external?.invalidate()
                do { try baseline.restore() }
                catch { XCTFail("恢复测试前显示配置失败：\(error.localizedDescription)") }
            }
        }
        let externalID = try XCTUnwrap(external?.displayID)
        try await waitUntil { CGDisplayIsOnline(externalID) != 0 }
        let externalUUID = DisplayRecoveryRecord.canonicalIdentifier(try DisplayRecoveryRecord.uuid(externalID))
        let desktop = try manager.activate(requestedPixels: .init(width: 1280, height: 720),
                                           mirroring: externalID, refreshRate: 60)
        XCTAssertTrue(store.exists)
        external?.invalidate()
        external = nil
        try await waitUntil { !(try MacDisplayRouting.onlineDisplays()).contains(externalID) }
        try manager.reconcileDisplays()
        XCTAssertNil(manager.activePhysicalDisplayID)
        XCTAssertEqual(manager.activeDisplayID, desktop.displayID)
        XCTAssertTrue(try manager.consumeCaptureRestartAfterDisplayChange())
        XCTAssertFalse(try manager.consumeCaptureRestartAfterDisplayChange(), "每次拔线只允许重建采集一次")
        XCTAssertTrue(store.exists, "拔线不能抹掉原硬件的配置")
        let reused = try manager.activate(requestedPixels: desktop.pixelDimensions, mirroring: nil, refreshRate: 60)
        XCTAssertEqual(reused.displayID, desktop.displayID)
        guard CGPreflightScreenCaptureAccess() else {
            throw NSError(domain: "显示器热插拔测试", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "测试没有已有录屏授权，不请求新权限"])
        }
        let content = try await SCShareableContent.current
        let source = try XCTUnwrap(content.displays.first { $0.displayID == desktop.displayID })
        let configuration = SCStreamConfiguration()
        configuration.width = 1280
        configuration.height = 720
        configuration.capturesAudio = false
        let frame = expectation(description: "移除镜像屏后仍收到虚拟桌面画面")
        let output = HeadlessCaptureOutput { width, height in
            XCTAssertEqual(width, 1280)
            XCTAssertEqual(height, 720)
            frame.fulfill()
        }
        let capture = SCStream(filter: SCContentFilter(display: source, excludingWindows: []),
                               configuration: configuration, delegate: nil)
        try capture.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "拔线画面测试"))
        try await capture.startCapture()
        await fulfillment(of: [frame], timeout: 8)
        try await capture.stopCapture()
        manager.deactivate()
        XCTAssertNil(manager.activeDisplayID)
        XCTAssertTrue(store.exists)
        // 原屏尚未插回时，遗留恢复记录也不能阻止重新开始独立桌面。
        let restarted = try manager.activate(requestedPixels: desktop.pixelDimensions, mirroring: nil, refreshRate: 60)
        XCTAssertNil(restarted.physicalDisplayID)
        XCTAssertTrue(store.exists)
        // 重插同一显示器后按硬件标识恢复，不沿用可能过期的显示编号。
        external = try autoreleasepool { try YCVirtualDisplayBridge(pixelWidth: 1280, pixelHeight: 800, refreshRate: 60) }
        let reattachedID = try XCTUnwrap(external?.displayID)
        try await waitUntil { CGDisplayIsOnline(reattachedID) != 0 }
        XCTAssertEqual(DisplayRecoveryRecord.canonicalIdentifier(try DisplayRecoveryRecord.uuid(reattachedID)), externalUUID)
        try manager.reconcileDisplays()
        XCTAssertFalse(store.exists)
        XCTAssertEqual(manager.activeDisplayID, restarted.displayID)
        XCTAssertNil(manager.activePhysicalDisplayID, "重插不强行打断独立桌面")
        XCTAssertEqual(CGDisplayMirrorsDisplay(reattachedID), kCGNullDirectDisplay)
        // 虚拟屏移除是异步系统事务，清理完成后才能让下一个测试抓取真实显示配置。
        manager.deactivate()
        external?.invalidate()
        external = nil
        let baselineIDs = Set(baseline.entries.map(\.id))
        try await waitUntil { Set(try MacDisplayRouting.onlineDisplays()) == baselineIDs }
        try baseline.restore()
        baselineRestored = true
        var stableReadings = 0
        try await waitUntil {
            let matches = Set(try MacDisplayRouting.onlineDisplays()) == baselineIDs && baseline.entries.allSatisfy {
                CGDisplayCopyDisplayMode($0.id)?.pixelWidth == $0.mode.pixelWidth &&
                CGDisplayCopyDisplayMode($0.id)?.pixelHeight == $0.mode.pixelHeight &&
                CGDisplayMirrorsDisplay($0.id) == $0.mirrorSource
            }
            stableReadings = matches ? stableReadings + 1 : 0
            return stableReadings >= 3
        }
    }

    func testStandaloneDesktopDoesNotSwitchWhenAnotherDisplayAppears() throws {
        XCTAssertNil(try MacDisplayRouting.mirrorTarget(selected: nil, online: [1, 92], ownedVirtualDisplay: 92))
    }

    private func waitUntil(_ predicate: () throws -> Bool) async throws {
        for _ in 0..<60 {
            if try predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "显示器热插拔测试", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "等待真实显示器拓扑变更超时"])
    }
}
