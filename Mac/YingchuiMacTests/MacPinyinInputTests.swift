import AppKit
import Carbon
import XCTest
import YingchuiProtocol
@testable import YingchuiMac

final class MacPinyinInputTests: XCTestCase {
    func testPinyinAndNumberKeyCodesMatchMacKeyboard() {
        let codes = "nihao123".compactMap { RemoteKeyboardStroke(character: $0) }.map { MacInputMapping.keyCode(for: $0.key) }
        XCTAssertEqual(codes, [45, 34, 4, 0, 31, 18, 19, 20])
        let letters = "abcdefghijklmnopqrstuvwxyz".compactMap { RemoteKeyboardStroke(character: $0) }.map { MacInputMapping.keyCode(for: $0.key) }
        XCTAssertEqual(Set(letters).count, 26)
    }

    @MainActor
    func testMacPinyinComposesAndCommitsInTemporaryTextView() async throws {
        let input = MacInputController()
        guard input.isAccessibilityGranted else {
            XCTFail("测试应用未获得辅助功能权限，无法验证原生拼音注入")
            return
        }
        let previous = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let window = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 560, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "中文输入验证"
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 200))
        text.isRichText = false
        text.font = .systemFont(ofSize: 24)
        window.contentView = text
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(text)
        defer {
            XCTAssertEqual(TISSelectInputSource(previous), noErr, "恢复原输入法失败")
            window.orderOut(nil)
        }
        let focusDeadline = ContinuousClock.now + .seconds(3)
        while !(NSApp.isActive && window.isKeyWindow && window.firstResponder === text), ContinuousClock.now < focusDeadline {
            window.makeKeyAndOrderFront(nil)
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            window.makeFirstResponder(text)
            try await Task.sleep(for: .milliseconds(100))
        }
        guard NSApp.isActive && window.isKeyWindow && window.firstResponder === text else {
            XCTFail("临时输入窗口未获得焦点：应用活动 \(NSApp.isActive)，关键窗口 \(window.isKeyWindow)，前台 \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "未知")")
            return
        }
        try MacKeyboardInputSource.select(.pinyin)
        try await Task.sleep(for: .milliseconds(300))
        for letter in "nihao" {
            let stroke = try XCTUnwrap(RemoteKeyboardStroke(character: letter))
            XCTAssertTrue(input.pressKey(stroke.key, modifiers: stroke.modifiers))
            try await Task.sleep(for: .milliseconds(70))
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(text.hasMarkedText(), "Mac 应显示正在组词的拼音，实际内容：\(text.string)")
        XCTAssertTrue(input.pressKey(.space, modifiers: []))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(text.hasMarkedText())
        XCTAssertNotNil(text.string.range(of: "\\p{Han}", options: .regularExpression), "空格应确认中文候选字")
        try MacKeyboardInputSource.select(.english)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(input.pressKey(.letterA, modifiers: []))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(text.string.hasSuffix("a"), "切回英文后应直接输入字母，实际内容：\(text.string)")
    }
}
