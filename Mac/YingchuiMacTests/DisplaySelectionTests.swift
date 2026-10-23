import AppKit
import SwiftUI
import XCTest
@testable import YingchuiMac

@MainActor
final class DisplaySelectionTests: XCTestCase {
    private let display = MacDisplayOption(id: 10, name: "测试显示器", resolution: "1280×720")

    func testRetainedPickerBindingRemainsValidAfterLastDisplayIsRemoved() {
        let host = MacHostModel(startServices: false)
        host.availableDisplays = [display]
        host.selectedDisplayID = display.id
        let retainedBinding = host.displaySelectionBinding
        XCTAssertEqual(retainedBinding.wrappedValue, display.id)
        host.availableDisplays = []
        XCTAssertNil(retainedBinding.wrappedValue, "列表先清空而选择尚未清除时也必须安全")
        host.selectedDisplayID = nil
        XCTAssertNil(retainedBinding.wrappedValue, "SwiftUI 移除控件后仍可能读取旧绑定")
    }

    func testStalePickerWriteDoesNotSelectRemovedHardware() {
        let host = MacHostModel(startServices: false)
        host.availableDisplays = [display]
        let retainedBinding = host.displaySelectionBinding
        host.availableDisplays = []
        retainedBinding.wrappedValue = display.id
        XCTAssertNil(host.selectedDisplayID)
        XCTAssertNil(host.selectedDisplayForStreaming.value)
        XCTAssertEqual(host.streamStatusText, "所选显示器已断开，请重新选择")
    }

    func testSelectionDoesNotInventDisplayWhenListIsEmptyOrSelectionIsMissing() {
        let host = MacHostModel(startServices: false)
        XCTAssertNil(host.displaySelectionBinding.wrappedValue)
        host.availableDisplays = [display]
        XCTAssertNil(host.displaySelectionBinding.wrappedValue)
        host.selectedDisplayID = display.id
        XCTAssertEqual(host.displaySelectionBinding.wrappedValue, display.id)
    }

    func testActualHostingViewSurvivesRepeatedDisplayRemovalDuringLayout() async throws {
        let host = MacHostModel(startServices: false)
        host.availableDisplays = [display]
        host.selectedDisplayID = display.id
        let view = NSHostingView(rootView: ContentView(host: host, account: AccountModel()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 460),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        for _ in 0..<12 {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            host.availableDisplays = []
            host.selectedDisplayID = nil
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertNil(host.displaySelectionBinding.wrappedValue)
            host.availableDisplays = [display]
            host.selectedDisplayID = display.id
        }
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.displaySelectionBinding.wrappedValue, display.id)
    }
}
