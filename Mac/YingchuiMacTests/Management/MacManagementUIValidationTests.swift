import AppKit
import SwiftUI
import Sparkle
import XCTest
@testable import YingchuiMac

@MainActor
final class MacManagementUIValidationTests: XCTestCase {
    func testSparkleReceivesSecurityAndInstallationDelegates() {
        let updates = MacUpdateController()
        for selector in ["updater:mayPerformUpdateCheck:error:", "updater:shouldProceedWithUpdate:updateCheck:error:",
                         "updaterShouldRelaunchApplication:",
                         "feedURLStringForUpdater:", "allowedChannelsForUpdater:",
                         "userDidCancelDownload:",
                         "updater:didFinishUpdateCycleForUpdateCheck:error:"] {
            XCTAssertTrue(updates.responds(to: NSSelectorFromString(selector)), "Sparkle 委托没有正确接线：\(selector)")
        }
    }

    func testUnavailableBackendIsReportedWithoutClaimingInstallation() {
        let updates = MacUpdateController()
        let sparkle = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil).updater
        updates.updater(sparkle, didAbortWithError: MacManagementError.unavailable)
        XCTAssertEqual(updates.state, .failed)
        updates.updater(sparkle, didAbortWithError: MacManagementError.streaming)
        XCTAssertEqual(updates.state, .failed)
        updates.updater(sparkle, didAbortWithError: NSError(domain: "本地测试", code: -1))
        XCTAssertEqual(updates.state, .failed)
    }

    func testSettingsUpdateRowFitsNativeLayout() throws {
        let host = MacHostModel(startServices: false)
        let view = NSHostingView(rootView: MacSettingsView(host: host, updates: MacUpdateController()))
        let size = view.fittingSize
        XCTAssertEqual(size.width, 420, accuracy: 1)
        XCTAssertLessThan(size.height, 650)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let path = URL(fileURLWithPath: "/Users/chongyang/iPhone_Project/Yingchui/yingchuihulian/work/repair/mac-management/settings.png")
        try image.write(to: path)
    }
}
