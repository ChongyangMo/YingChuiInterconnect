import UIKit
import XCTest
@testable import YingchuiPad
import YingchuiProtocol

@MainActor
final class RemoteKeyboardInputTests: XCTestCase {
    func testFastTypingAndEditingAreForwardedOnceInOrder() {
        let field = RemoteTypingTextField()
        var events: [String] = []
        field.onText = { events.append($0) }
        field.onKey = { key, _ in events.append(key.rawValue) }
        let characters = Array(String(repeating: "abc123", count: 30))
        for character in characters { field.insertText(String(character)) }
        field.deleteBackward()
        _ = field.textFieldShouldReturn(field)
        XCTAssertEqual(events, characters.map(String.init) + ["deleteBackward", "returnKey"])
        XCTAssertEqual(field.text, "")
    }

    func testChineseCompositionOnlySendsConfirmedText() {
        let field = RemoteTypingTextField()
        var events: [String] = []
        field.onText = { events.append($0) }
        field.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        field.commitText()
        XCTAssertTrue(events.isEmpty)
        field.setMarkedText("你好", selectedRange: NSRange(location: 2, length: 0))
        field.commitText()
        XCTAssertTrue(events.isEmpty)
        field.unmarkText()
        XCTAssertEqual(events, ["你好"])
        field.commitText()
        XCTAssertEqual(events, ["你好"])
    }

    func testBackspaceInsideCompositionDoesNotDeleteMacText() {
        let field = RemoteTypingTextField()
        var keys: [RemoteKey] = []
        var text: [String] = []
        field.onText = { text.append($0) }
        field.onKey = { key, _ in keys.append(key) }
        field.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        field.deleteBackward()
        XCTAssertTrue(keys.isEmpty)
        XCTAssertTrue(text.isEmpty)
    }

    func testCandidateReplacementDoesNotSendPinyin() {
        let field = RemoteTypingTextField()
        var text: [String] = []
        field.onText = { text.append($0) }
        field.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        field.insertText("你")
        XCTAssertEqual(text, ["你"])
    }

    func testHeldAndRapidRepeatedKeysReleaseWithoutStaleHighlights() async throws {
        let state = RemoteKeyboardState()
        state.press(4, modifiers: [])
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(state.pressedKeys.contains(4))
        state.release(4, modifiers: [])
        state.press(4, modifiers: [])
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(state.pressedKeys.contains(4))
        state.release(4, modifiers: [])
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(state.pressedKeys.contains(4))
        state.press(225, modifiers: [.shift])
        state.press(227, modifiers: [.shift, .command])
        XCTAssertTrue(state.shiftHeld)
        state.reset()
        XCTAssertTrue(state.pressedKeys.isEmpty)
        XCTAssertFalse(state.shiftHeld)
    }

    func testHIDMatchingIsIndependentOfShiftedCharacters() {
        XCTAssertEqual(RemoteKeyboardHID.code(for: "a"), 4)
        XCTAssertEqual(RemoteKeyboardHID.code(for: "A"), 4)
        XCTAssertEqual(RemoteKeyboardHID.code(for: "!"), RemoteKeyboardHID.code(for: "1"))
        XCTAssertEqual(RemoteKeyboardHID.code(for: "?"), RemoteKeyboardHID.code(for: "/"))
        XCTAssertEqual(RemoteKeyboardHID.code(for: " "), 44)
    }
}
