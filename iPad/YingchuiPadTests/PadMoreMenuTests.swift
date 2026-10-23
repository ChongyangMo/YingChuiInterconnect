import SwiftUI
import UIKit
import XCTest
import YingchuiProtocol
@testable import YingchuiPad

final class PadMoreMenuTests: XCTestCase {
    @MainActor
    func testStreamingUpdatesPreserveNativeButtonAndMenuIdentity() async throws {
        let model = PadConnectionModel(startServices: false)
        let host = UIHostingController(rootView: UpdatingMenuHost(model: model))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        let button = try XCTUnwrap(findButton(host.view))
        let menu = try XCTUnwrap(button.menu)
        XCTAssertEqual(button.bounds.size, CGSize(width: 44, height: 44))
        XCTAssertTrue(button.showsMenuAsPrimaryAction)
        XCTAssertTrue(menu.children.first is UIDeferredMenuElement)
        if #available(iOS 17.4, *) {
            button.performPrimaryAction()
        } else {
            XCTFail("菜单展开验证需要 iOS 17.4 或更新版本")
            return
        }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(button.isHeld, "原生菜单必须实际展开")
        defer { button.contextMenuInteraction?.dismissMenu() }
        for frame in 1...60 {
            model.videoFramesDecoded = UInt64(frame)
            model.videoIsPlaying = true
            try await Task.sleep(for: .milliseconds(16))
            host.view.layoutIfNeeded()
            XCTAssertTrue(findButton(host.view) === button)
            XCTAssertTrue(button.menu === menu, "播放刷新不能替换展开中的菜单")
            XCTAssertTrue(button.isHeld, "连续刷新不能关闭已展开的菜单")
        }
    }

    @MainActor
    func testNestedMenusStayFrozenAndNextOpeningReadsNewSettings() throws {
        let model = PadConnectionModel(startServices: false)
        model.isPaired = true
        model.selectedDisplayMode = .extended
        model.resolutionOptions = [.native]
        let name = "PadMoreMenuTests.\(UUID().uuidString)"
        let prefs = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { prefs.removePersistentDomain(forName: name) }
        let builder = PadMoreMenuItems(model: model, showKeyboard: {}, exitFullScreen: {},
                                      exportDiagnostics: { _ in }, preferences: prefs)
        let first = builder.makeItems()
        let display = try XCTUnwrap(first[2] as? UIMenu)
        let position = try XCTUnwrap(display.children.compactMap { $0 as? UIMenu }.first)
        XCTAssertEqual(position.title, "屏幕位置")
        XCTAssertEqual(position.children.map(\.title), ["左侧", "右侧", "上方", "下方"])
        XCTAssertEqual((first[3] as? UIMenu)?.children.count, 1)
        let controls = try XCTUnwrap(first[0] as? UIMenu)
        XCTAssertEqual((controls.children[0] as? UIAction)?.state, .on)
        let touch = try XCTUnwrap(controls.children[1] as? UIAction)
        let trigger = UIButton()
        trigger.addAction(touch, for: .primaryActionTriggered)
        trigger.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(prefs.string(forKey: PadControlMode.preferenceKey), PadControlMode.touch.rawValue)
        XCTAssertEqual((controls.children[0] as? UIAction)?.state, .on, "当前菜单快照不能被后台设置修改")
        let next = try XCTUnwrap(builder.makeItems()[0] as? UIMenu)
        XCTAssertEqual((next.children[1] as? UIAction)?.state, .on)
        XCTAssertEqual((next.children[0] as? UIAction)?.state, .off)
    }

    @MainActor
    func testDeveloperVisibilityConnectionAvailabilityAndCallbacks() throws {
        let model = PadConnectionModel(startServices: false)
        let name = "PadMoreMenuTests.\(UUID().uuidString)"
        let prefs = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { prefs.removePersistentDomain(forName: name) }
        var keyboardCount = 0
        var exitCount = 0
        var exported: String?
        let builder = PadMoreMenuItems(model: model, showKeyboard: { keyboardCount += 1 },
                                      exitFullScreen: { exitCount += 1 },
                                      exportDiagnostics: { exported = $0 }, preferences: prefs)
        let normal = leaves(builder.makeItems())
        XCTAssertFalse(normal.contains { $0.title == "请求关键帧" })
        XCTAssertTrue(try XCTUnwrap(normal.first { $0.title == "键盘" }).attributes.contains(.disabled))
        model.isPaired = true
        model.isStreaming = true
        prefs.set(true, forKey: PadSettings.developerModeKey)
        let actions = leaves(builder.makeItems())
        XCTAssertFalse(try XCTUnwrap(actions.first { $0.title == "请求关键帧" }).attributes.contains(.disabled))
        for title in ["键盘", "退出全屏", "导出诊断"] {
            let action = try XCTUnwrap(actions.first { $0.title == title })
            let trigger = UIButton()
            trigger.addAction(action, for: .primaryActionTriggered)
            trigger.sendActions(for: .primaryActionTriggered)
        }
        XCTAssertEqual(keyboardCount, 1)
        XCTAssertEqual(exitCount, 1)
        XCTAssertFalse(try XCTUnwrap(exported).isEmpty)
    }

    @MainActor
    private func leaves(_ items: [UIMenuElement]) -> [UIAction] {
        items.flatMap { item -> [UIAction] in
            if let menu = item as? UIMenu { return leaves(menu.children) }
            return (item as? UIAction).map { [$0] } ?? []
        }
    }

    @MainActor
    private func findButton(_ view: UIView) -> SnapshotMenuButton? {
        if let button = view as? SnapshotMenuButton { return button }
        return view.subviews.lazy.compactMap { self.findButton($0) }.first
    }
}

private struct UpdatingMenuHost: View {
    @ObservedObject var model: PadConnectionModel
    var body: some View {
        VStack {
            Text("\(model.videoFramesDecoded)")
            PadMoreMenu(model: model, onExitFullScreen: {}) {}
        }
    }
}
