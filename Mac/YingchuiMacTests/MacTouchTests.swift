import ApplicationServices
import XCTest
import YingchuiProtocol
@testable import YingchuiMac

final class MacTouchTests: XCTestCase {
    func testScrollStagesUseNativeScrollAndMomentumFields() throws {
        let cases: [(RemoteScrollPhase, Int64, Int64)] = [
            (.began, 1, 0), (.changed, 2, 0), (.ended, 4, 0), (.cancelled, 8, 0),
            (.momentumBegan, 0, 1), (.momentumChanged, 0, 2), (.momentumEnded, 0, 3)
        ]
        for (phase, scroll, momentum) in cases {
            let input = RemoteTouchInput(phase: .scroll, x: 0.5, y: 0.5, deltaX: 0, deltaY: 3, scrollPhase: phase)
            let event = try XCTUnwrap(MacTouchEventFactory.events(for: input,
                bounds: CGRect(x: 0, y: 0, width: 100, height: 100)).last)
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventScrollPhase), scroll)
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventMomentumPhase), momentum)
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventIsContinuous), 1)
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 3)
        }
    }

    func testHoverOnlyMovesPointerWithoutPressingAnyMouseButton() throws {
        let hover = RemoteTouchInput(phase: .hover, x: 0.25, y: 0.75)
        let events = try MacTouchEventFactory.events(for: hover,
            bounds: CGRect(x: -1000, y: 200, width: 1000, height: 800))
        XCTAssertEqual(events.map(\.type), [.mouseMoved])
        XCTAssertEqual(events.first?.location, CGPoint(x: -750, y: 800))
        XCTAssertEqual(events.first?.getIntegerValueField(.mouseEventClickState), 0)
    }

    func testHoverCannotBeInjectedDuringAnUnfinishedDrag() throws {
        let host = MacHostModel(startServices: false)
        let hover = RemoteTouchInput(phase: .hover, x: 0.5, y: 0.5)
        XCTAssertNoThrow(try host.validateTouchTransition(hover, activeGesture: nil))
        XCTAssertThrowsError(try host.validateTouchTransition(hover, activeGesture: UUID()))
    }

    func testAbsoluteMappingHandlesRetinaAndNegativeDisplayOrigin() throws {
        let input = RemoteTouchInput(phase: .tap, x: 0.5, y: 0.5)
        XCTAssertEqual(try MacTouchEventFactory.position(for: input, bounds: CGRect(x: 0, y: 0, width: 1112, height: 834)),
                       CGPoint(x: 556, y: 417))
        XCTAssertEqual(try MacTouchEventFactory.position(for: input, bounds: CGRect(x: -1920, y: -1080, width: 1920, height: 1080)),
                       CGPoint(x: -960, y: -540))
        XCTAssertEqual(try MacTouchEventFactory.position(for: RemoteTouchInput(phase: .tap, x: 1, y: 1),
            bounds: CGRect(x: -100, y: 200, width: 100, height: 200)), CGPoint(x: -1, y: 399))
    }

    func testClickAndDragEventsUseExactTargetAndCorrectEventTypes() throws {
        let bounds = CGRect(x: 100, y: 200, width: 1000, height: 800)
        let tap = try MacTouchEventFactory.events(for: RemoteTouchInput(phase: .tap, x: 0.25, y: 0.75), bounds: bounds, clickCount: 2)
        XCTAssertEqual(tap.map(\.type), [.mouseMoved, .leftMouseDown, .leftMouseUp])
        XCTAssertTrue(tap.allSatisfy { $0.location == CGPoint(x: 350, y: 800) })
        XCTAssertEqual(tap[1].getIntegerValueField(.mouseEventClickState), 2)
        let drag = try MacTouchEventFactory.events(for: RemoteTouchInput(phase: .dragMoved, x: 0.5, y: 0.5, gestureID: UUID()), bounds: bounds)
        XCTAssertEqual(drag.map(\.type), [.leftMouseDragged])
    }

    func testRightClickAndScrollAreAnchoredAtTouchedPoint() throws {
        let bounds = CGRect(x: -500, y: 0, width: 500, height: 500)
        let right = try MacTouchEventFactory.events(for: RemoteTouchInput(phase: .rightTap, x: 0.5, y: 0.5), bounds: bounds)
        XCTAssertEqual(right.map(\.type), [.mouseMoved, .rightMouseDown, .rightMouseUp])
        let scroll = try MacTouchEventFactory.events(for: RemoteTouchInput(phase: .scroll, x: 0.5, y: 0.5, deltaX: 10, deltaY: -20), bounds: bounds)
        XCTAssertEqual(scroll.map(\.type), [.mouseMoved, .scrollWheel])
        XCTAssertEqual(scroll.last?.location, CGPoint(x: -250, y: 250))
    }

    func testTapSequenceRecognizesDoubleClickWithoutDelayingFirstClick() {
        var sequence = MacTouchClickSequence()
        let point = CGPoint(x: 100, y: 100)
        XCTAssertEqual(sequence.clickCount(at: point, now: 0, interval: 0.5), 1)
        XCTAssertEqual(sequence.clickCount(at: point, now: 0.2, interval: 0.5), 2)
        XCTAssertEqual(sequence.clickCount(at: point, now: 0.3, interval: 0.5), 1)
        XCTAssertEqual(sequence.clickCount(at: CGPoint(x: 200, y: 100), now: 0.4, interval: 0.5), 1)
        XCTAssertEqual(sequence.clickCount(at: point, now: 1, interval: 0.5), 1)
    }

    func testInvalidDisplayAndCoordinatesCannotGenerateInput() {
        XCTAssertThrowsError(try MacTouchEventFactory.events(for: RemoteTouchInput(phase: .tap, x: 0, y: 0), bounds: .zero))
        XCTAssertThrowsError(try MacTouchEventFactory.events(for: RemoteTouchInput(phase: .tap, x: 2, y: 0), bounds: CGRect(x: 0, y: 0, width: 100, height: 100)))
    }

    func testOutOfOrderAndStaleDragIDsAreRejected() throws {
        let host = MacHostModel(startServices: false)
        let id = UUID()
        let begin = RemoteTouchInput(phase: .dragBegan, x: 0, y: 0, gestureID: id)
        let move = RemoteTouchInput(phase: .dragMoved, x: 0.5, y: 0.5, gestureID: id)
        XCTAssertNoThrow(try host.validateTouchTransition(begin, activeGesture: nil))
        XCTAssertThrowsError(try host.validateTouchTransition(begin, activeGesture: id))
        XCTAssertNoThrow(try host.validateTouchTransition(move, activeGesture: id))
        XCTAssertThrowsError(try host.validateTouchTransition(move, activeGesture: nil))
        XCTAssertThrowsError(try host.validateTouchTransition(move, activeGesture: UUID()))
        XCTAssertThrowsError(try host.validateTouchTransition(RemoteTouchInput(phase: .tap, x: 0, y: 0), activeGesture: id))
    }
}
