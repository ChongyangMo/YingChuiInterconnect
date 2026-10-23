import ApplicationServices
import XCTest
import YingchuiProtocol
@testable import YingchuiMac

final class MacPointerDragTests: XCTestCase {
    func testRelativeMovementPreservesHeldLeftAndRightButtons() throws {
        var state = RemoteButtonState()
        func move() throws -> CGEvent {
            try XCTUnwrap(MacPointerEventFactory.movement(from: CGPoint(x: 100, y: 100),
                deltaX: 25, deltaY: -10, buttons: state))
        }
        XCTAssertEqual(try move().type, .mouseMoved)
        state.record(.left, pressed: true)
        let drag = try move()
        XCTAssertEqual(drag.type, .leftMouseDragged)
        XCTAssertEqual(drag.location, CGPoint(x: 125, y: 90))
        XCTAssertEqual(drag.getDoubleValueField(.mouseEventDeltaX), 25)
        XCTAssertEqual(drag.getDoubleValueField(.mouseEventDeltaY), -10)
        XCTAssertEqual(drag.getIntegerValueField(.mouseEventClickState), 1)
        state.record(.right, pressed: true)
        XCTAssertEqual(try move().type, .leftMouseDragged)
        state.record(.left, pressed: false)
        XCTAssertEqual(try move().type, .rightMouseDragged)
        XCTAssertEqual(try move().getIntegerValueField(.mouseEventButtonNumber), 1)
        XCTAssertEqual(state.takePressedButtons(), [.right])
        XCTAssertEqual(try move().type, .mouseMoved)
        XCTAssertFalse(state.isPressed(.right))
    }

    func testAnotherSessionDoesNotInheritPressedButton() throws {
        var first = RemoteButtonState()
        first.record(.left, pressed: true)
        let event = try XCTUnwrap(MacPointerEventFactory.movement(from: .zero, deltaX: 10, deltaY: 0,
            buttons: RemoteButtonState()))
        XCTAssertEqual(event.type, .mouseMoved)
        XCTAssertNil(MacPointerEventFactory.movement(from: .zero, deltaX: .nan, deltaY: 0, buttons: first))
    }
}
