import AppKit
import ApplicationServices
import XCTest
import YingchuiProtocol
@testable import YingchuiMac

final class MacTouchInjectionTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testRealEventsReachOwnedWindowWithDoubleClickDragAndScroll() async throws {
        XCTAssertTrue(AXIsProcessTrusted(), "实机触摸注入验证需要已有辅助功能授权")
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let frame = CGRect(x: screen.visibleFrame.midX - 180, y: screen.visibleFrame.midY - 140, width: 360, height: 280)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "触摸自动验证"
        window.level = .floating
        window.isReleasedWhenClosed = false
        let target = TouchTestTarget(frame: CGRect(origin: .zero, size: frame.size))
        window.contentView = target
        let received = expectation(description: "触摸注入到达测试窗口")
        target.onScroll = { received.fulfill() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        let cocoaPoint = window.convertPoint(toScreen: CGPoint(x: 180, y: 140))
        let quartzPoint = CGPoint(x: cocoaPoint.x, y: screen.frame.maxY - cocoaPoint.y)
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let x = (quartzPoint.x - bounds.minX) / bounds.width
        let y = (quartzPoint.y - bounds.minY) / bounds.height
        let id = UUID()
        var sequence = MacTouchClickSequence()
        let touches = [
            RemoteTouchInput(phase: .tap, x: x, y: y),
            RemoteTouchInput(phase: .tap, x: x, y: y),
            RemoteTouchInput(phase: .rightTap, x: x, y: y),
            RemoteTouchInput(phase: .dragBegan, x: x, y: y, gestureID: id),
            RemoteTouchInput(phase: .dragMoved, x: x + 0.01, y: y, gestureID: id),
            RemoteTouchInput(phase: .dragEnded, x: x + 0.01, y: y, gestureID: id),
            RemoteTouchInput(phase: .scroll, x: x, y: y, deltaX: 0, deltaY: 20)
        ]
        for (index, touch) in touches.enumerated() {
            var decoder = WireMessageDecoder()
            let wire = WireMessage(kind: .touchInput, streamID: UUID(), touch: touch)
            let decoded = try XCTUnwrap(decoder.append(WireCodec.encode(wire)).first)
            guard case .touchInput(let command) = try RemoteControlValidator.command(from: decoded) else {
                return XCTFail("触摸协议未生成控制命令")
            }
            let count = touch.phase == .tap
                ? sequence.clickCount(at: quartzPoint, now: Double(index) * 0.1, interval: 0.5) : 1
            for event in try MacTouchEventFactory.events(for: command, bounds: bounds, clickCount: count) {
                event.post(tap: .cghidEventTap)
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        await fulfillment(of: [received], timeout: 5)
        XCTAssertEqual(target.clickCounts, [1, 2, 1])
        XCTAssertEqual(target.rightClicks, 1)
        XCTAssertEqual(target.drags, 1)
        XCTAssertEqual(target.releases, 3)
        XCTAssertGreaterThan(target.scrollAmount, 0)
    }
}

@MainActor
private final class TouchTestTarget: NSView {
    var clickCounts: [Int] = []
    var rightClicks = 0
    var drags = 0
    var releases = 0
    var scrollAmount = 0.0
    var onScroll: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { clickCounts.append(event.clickCount) }
    override func mouseUp(with event: NSEvent) { releases += 1 }
    override func mouseDragged(with event: NSEvent) { drags += 1 }
    override func rightMouseDown(with event: NSEvent) { rightClicks += 1 }
    override func rightMouseUp(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {
        scrollAmount += event.scrollingDeltaY
        onScroll?()
    }
}
