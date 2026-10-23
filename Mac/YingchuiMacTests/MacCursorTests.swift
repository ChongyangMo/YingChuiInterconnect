import AppKit
import XCTest
import YingchuiProtocol
@testable import YingchuiMac

final class MacCursorTests: XCTestCase {
    @MainActor
    func testSystemShapeIsBoundedAndReadCostIsMeasured() throws {
        let start = CFAbsoluteTimeGetCurrent()
        var largest = 0
        for _ in 0..<50 {
            let shape = try MacCursorMonitor.readShape()
            XCTAssertTrue(shape.isValid)
            largest = max(largest, shape.png.count)
        }
        let perRead = (CFAbsoluteTimeGetCurrent() - start) * 1_000 / 50
        print("光标形状读取实测：平均 \(perRead) 毫秒，最大图像 \(largest) 字节")
        XCTAssertLessThan(perRead, 16.7, "光标读取不能耗尽一帧主线程预算")
    }

    func testPositionAndDragTypeSurviveEventTagging() throws {
        var buttons = RemoteButtonState()
        buttons.record(.left, pressed: true)
        let input = RemoteCursorInput(position: .init(x: -500, y: 250), sequence: 71)
        let event = try XCTUnwrap(MacPointerEventFactory.movement(from: .init(x: 100, y: 100),
            deltaX: -600, deltaY: 150, buttons: buttons))
        event.setIntegerValueField(.eventSourceUserData, value: input.eventTag)
        XCTAssertEqual(event.type, .leftMouseDragged)
        XCTAssertEqual(event.location, CGPoint(x: -500, y: 250))
        XCTAssertEqual(RemoteCursorInput.sequence(fromEventTag: event.getIntegerValueField(.eventSourceUserData)), 71)
    }

    @MainActor
    func testSystemEventMustBeObservedBeforeCursorAcknowledgesInput() async throws {
        let monitor = MacCursorMonitor(displayID: CGMainDisplayID())
        let initial = try monitor.prepare()
        defer { monitor.stop() }
        XCTAssertEqual(initial.acknowledgedInput, 0)
        let observed = expectation(description: "系统已处理带序号的光标事件")
        monitor.onFailure = { XCTFail($0) }
        var fulfilled = false
        monitor.onUpdate = { state in
            if state.acknowledgedInput == 73 && !fulfilled { fulfilled = true; observed.fulfill() }
        }
        monitor.start()
        let input = RemoteCursorInput(position: initial.position, sequence: 73)
        let event = try XCTUnwrap(MacPointerEventFactory.movement(
            from: CGPoint(x: initial.position.x, y: initial.position.y), deltaX: 0, deltaY: 0,
            buttons: RemoteButtonState()))
        event.setIntegerValueField(.eventSourceUserData, value: input.eventTag)
        event.post(tap: .cghidEventTap)
        await fulfillment(of: [observed], timeout: 3)
    }
}
