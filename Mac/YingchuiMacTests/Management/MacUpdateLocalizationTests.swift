import AppKit
import Sparkle
import XCTest
@testable import YingchuiMac

final class MacUpdateLocalizationTests: XCTestCase {
    func testHostDeclaresChineseOnlyEvenWithEnglishSystemPreference() throws {
        let host = Bundle.main
        XCTAssertEqual(host.developmentLocalization, "zh-Hans")
        XCTAssertEqual(host.object(forInfoDictionaryKey: "CFBundleLocalizations") as? [String], ["zh-Hans"])
        XCTAssertEqual(Bundle.preferredLocalizations(from: host.localizations, forPreferences: ["en-US"]), ["zh-Hans"])
        XCTAssertEqual(host.object(forInfoDictionaryKey: "CFBundleName") as? String, "鹰锤互联")
        XCTAssertEqual(host.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "鹰锤互联")
    }

    func testNativeUpdaterSelectsChineseForEveryStage() {
        let sparkle = Bundle(for: SPUStandardUserDriver.self)
        XCTAssertEqual(sparkle.preferredLocalizations, ["zh_CN"])
        let titles = [
            "You’re up to date!", "OK", "Cancel", "Software Update",
            "Checking for updates…", "Downloading update…", "Extracting update…",
            "Installing update…", "Ready to Install", "Install and Relaunch",
            "Skip This Version", "Remind Me Later", "Update Installed",
            "Unable to Check For Updates", "Update Error!"
        ]
        for title in titles {
            let translation = sparkle.localizedString(forKey: title, value: nil, table: "Sparkle")
            XCTAssertNotEqual(translation, title, "更新界面缺少中文：\(title)")
            XCTAssertNil(translation.range(of: "[A-Za-z]", options: .regularExpression), translation)
        }
        let template = sparkle.localizedString(forKey: "%@ %@ is currently the newest version available.", value: nil, table: "Sparkle")
        let message = String(format: template, "鹰锤互联", "1.0")
        XCTAssertTrue(message.contains("最新版本"))
        XCTAssertNil(message.range(of: "[A-Za-z]", options: .regularExpression))
    }

    func testAllNoUpdateReasonsAreChineseAndKeepFrameworkMetadata() {
        for reason in [SPUNoUpdateFoundReason.unknown, .onLatestVersion, .onNewerThanLatestVersion,
                       .systemIsTooOld, .systemIsTooNew, .hardwareDoesNotSupportARM64] {
            let original = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue), userInfo: [
                NSLocalizedDescriptionKey: "You're up to date!", NSLocalizedRecoverySuggestionErrorKey: "Requires Apple silicon Mac.",
                SPUNoUpdateFoundReasonKey: NSNumber(value: reason.rawValue), SPUNoUpdateFoundUserInitiatedKey: true
            ])
            let result = MacUpdatePresentation.noUpdate(original)
            XCTAssertEqual(result.domain, original.domain)
            XCTAssertEqual(result.code, original.code)
            XCTAssertEqual(result.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber, NSNumber(value: reason.rawValue))
            XCTAssertEqual(result.userInfo[SPUNoUpdateFoundUserInitiatedKey] as? Bool, true)
            XCTAssertEqual(result.localizedRecoveryOptions, ["好"])
            XCTAssertNil((result.localizedDescription + (result.localizedRecoverySuggestion ?? "")).range(of: "[A-Za-z]", options: .regularExpression))
        }
    }

    func testNetworkAndSignatureErrorsCannotLeakEnglishIntoAlerts() {
        let network = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                              userInfo: [NSLocalizedDescriptionKey: "The request timed out."])
        let signature = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.signatureError.rawValue),
                                userInfo: [NSUnderlyingErrorKey: network, NSLocalizedDescriptionKey: "Invalid signature."])
        let unknown = NSError(domain: "Test", code: -123, userInfo: [NSLocalizedDescriptionKey: "Unknown failure."])
        for error in [network, signature, unknown] {
            let result = MacUpdatePresentation.failure(error)
            XCTAssertEqual(result.domain, error.domain)
            XCTAssertEqual(result.code, error.code)
            XCTAssertNil((result.localizedDescription + (result.localizedRecoverySuggestion ?? "")).range(of: "[A-Za-z]", options: .regularExpression))
        }
        XCTAssertTrue(MacUpdatePresentation.failureMessage(network).contains("超时"))
        XCTAssertTrue(MacUpdatePresentation.failureMessage(signature).contains("安全校验"))
        XCTAssertEqual(MacUpdatePresentation.failure(signature).userInfo[NSUnderlyingErrorKey] as? NSError, network)
        XCTAssertEqual(MacUpdatePresentation.failureMessage(MacManagementError.releaseWithdrawn), "这个更新版本已撤回。")
    }

    @MainActor
    func testChineseAlertRendersOffscreen() throws {
        let original = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue), userInfo: [
            SPUNoUpdateFoundReasonKey: NSNumber(value: SPUNoUpdateFoundReason.onLatestVersion.rawValue)
        ])
        let alert = NSAlert(error: MacUpdatePresentation.noUpdate(original))
        alert.alertStyle = .informational
        alert.layout()
        XCTAssertEqual(alert.messageText, "已是最新版本")
        XCTAssertTrue(alert.informativeText.contains("鹰锤互联"))
        XCTAssertEqual(alert.buttons.map(\.title), ["好"])
        let view = try XCTUnwrap(alert.window.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let path = URL(fileURLWithPath: "/Users/chongyang/iPhone_Project/Yingchui/yingchuihulian/work/repair/mac-management/update-chinese-alert.png")
        try png.write(to: path)
        let driver = MacUpdateUserDriver(hostBundle: .main, delegate: nil)
        XCTAssertTrue(driver.responds(to: NSSelectorFromString("showUpdateNotFoundWithError:acknowledgement:")))
        XCTAssertTrue(driver.responds(to: NSSelectorFromString("showUpdaterError:acknowledgement:")))
    }
}
