import UIKit
import XCTest
import YingchuiProtocol
@testable import YingchuiPad

final class DirectTouchTests: XCTestCase {
    @MainActor
    func testHoldAndSlideOnlyHoverThenLiftAllowsMenuSelection() throws {
        let input = DirectTouchInteraction()
        input.size = CGSize(width: 100, height: 100)
        input.aspectRatio = 1
        var events: [RemoteTouchInput] = []
        input.onSend = { events.append($0) }
        input.beginHover(at: CGPoint(x: 25, y: 25))
        input.beginDrag(at: CGPoint(x: 25, y: 25))
        input.tap(at: CGPoint(x: 25, y: 25))
        input.moveHover(to: CGPoint(x: 50, y: 75))
        input.moveHover(to: CGPoint(x: 200, y: -10))
        input.endHover()
        input.moveHover(to: CGPoint(x: 0, y: 0))
        XCTAssertEqual(events.map(\.phase), [.hover, .hover, .hover])
        XCTAssertEqual(events.last?.x, 1)
        XCTAssertEqual(events.last?.y, 0)
        input.tap(at: CGPoint(x: 50, y: 75))
        XCTAssertEqual(events.last?.phase, .tap)
        XCTAssertEqual(events.last?.x, 0.5)
        XCTAssertEqual(events.last?.y, 0.75)
        for event in events { XCTAssertNoThrow(try event.validate()) }
    }

    @MainActor
    func testHoverExcludesBlackBarsAndCannotOverlapDraggingOrScrolling() {
        let input = DirectTouchInteraction()
        input.size = CGSize(width: 100, height: 100)
        input.aspectRatio = 2
        var events: [RemoteTouchInput] = []
        input.onSend = { events.append($0) }
        input.beginHover(at: CGPoint(x: 50, y: 10))
        input.moveHover(to: CGPoint(x: 50, y: 50))
        XCTAssertTrue(events.isEmpty)
        input.beginDrag(at: CGPoint(x: 50, y: 50))
        input.beginHover(at: CGPoint(x: 50, y: 50))
        input.endDrag()
        input.beginHover(at: CGPoint(x: 50, y: 50))
        input.scroll(at: CGPoint(x: 50, y: 50), translation: CGPoint(x: 0, y: 10))
        input.moveHover(to: CGPoint(x: 60, y: 50))
        XCTAssertEqual(events.map(\.phase), [.dragBegan, .dragEnded, .hover, .scroll])
        input.tap(at: CGPoint(x: 50, y: 50), right: true)
        XCTAssertEqual(events.last?.phase, .rightTap)
    }

    @MainActor
    func testStreamChangeCancelsHoverAndIgnoresLateMovement() {
        let view = DirectTouchView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var old: [RemoteTouchInput] = []
        var next: [RemoteTouchInput] = []
        view.configure(aspectRatio: 1, streamID: UUID(), enabled: true) { old.append($0) }
        view.layoutSubviews()
        view.interaction.beginHover(at: CGPoint(x: 50, y: 50))
        view.configure(aspectRatio: 1, streamID: UUID(), enabled: true) { next.append($0) }
        view.interaction.moveHover(to: CGPoint(x: 75, y: 50))
        XCTAssertEqual(old.map(\.phase), [.hover])
        XCTAssertTrue(next.isEmpty)
        view.interaction.tap(at: CGPoint(x: 75, y: 50))
        XCTAssertEqual(next.map(\.phase), [.tap])
    }

    @MainActor
    func testOlderMacReceivesAnUpdateErrorInsteadOfUnknownHoverMessage() {
        let model = PadConnectionModel()
        let streamID = UUID()
        model.isPaired = true
        model.supportsDirectTouch = true
        model.activeStreamID = streamID
        model.sendTouch(RemoteTouchInput(phase: .hover, x: 0.5, y: 0.5), streamID: streamID)
        XCTAssertEqual(model.statusText, "请更新 Mac 以使用触摸悬停")
    }

    func testLetterboxTouchesAreExcludedAndCenterMapsExactly() throws {
        let size = CGSize(width: 1000, height: 1000)
        XCTAssertNil(DirectTouchGeometry.point(CGPoint(x: 500, y: 100), in: size, aspectRatio: 2))
        XCTAssertNil(DirectTouchGeometry.point(CGPoint(x: 500, y: 900), in: size, aspectRatio: 2))
        XCTAssertEqual(DirectTouchGeometry.point(CGPoint(x: 500, y: 500), in: size, aspectRatio: 2), CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(DirectTouchGeometry.point(CGPoint(x: 0, y: 250), in: size, aspectRatio: 2), .zero)
        XCTAssertEqual(DirectTouchGeometry.point(CGPoint(x: 1000, y: 750), in: size, aspectRatio: 2), CGPoint(x: 1, y: 1))
    }

    func testPillarboxAndKeyboardResizingKeepPositionsInVideoCoordinates() {
        XCTAssertNil(DirectTouchGeometry.point(CGPoint(x: 20, y: 100), in: CGSize(width: 1000, height: 500), aspectRatio: 1))
        let normal = DirectTouchGeometry.point(CGPoint(x: 750, y: 375), in: CGSize(width: 1000, height: 750), aspectRatio: 4.0 / 3)
        let keyboard = DirectTouchGeometry.point(CGPoint(x: 600, y: 150), in: CGSize(width: 1000, height: 300), aspectRatio: 4.0 / 3)
        XCTAssertEqual(normal, CGPoint(x: 0.75, y: 0.5))
        XCTAssertEqual(keyboard, normal)
    }

    func testInvalidGeometryDoesNotProduceCoordinates() {
        XCTAssertNil(DirectTouchGeometry.point(.zero, in: .zero, aspectRatio: 1))
        XCTAssertNil(DirectTouchGeometry.point(.zero, in: CGSize(width: 100, height: 100), aspectRatio: nil))
        XCTAssertNil(DirectTouchGeometry.point(CGPoint(x: CGFloat.nan, y: 1), in: CGSize(width: 100, height: 100), aspectRatio: 1))
    }

    @MainActor
    func testTapIsImmediateAndTwoTapsRemainTwoEvents() {
        let input = DirectTouchInteraction()
        input.size = CGSize(width: 100, height: 100)
        input.aspectRatio = 1
        var events: [RemoteTouchInput] = []
        input.onSend = { events.append($0) }
        input.tap(at: CGPoint(x: 25, y: 75))
        XCTAssertEqual(events.count, 1, "单击不能为了等待双击而延后发送")
        input.tap(at: CGPoint(x: 25, y: 75))
        XCTAssertEqual(events.map(\.phase), [.tap, .tap])
        XCTAssertEqual(events.first?.x, 0.25)
        XCTAssertEqual(events.first?.y, 0.75)
    }

    @MainActor
    func testDragIsOrderedClampedAndReleasedExactlyOnce() throws {
        let input = DirectTouchInteraction()
        input.size = CGSize(width: 100, height: 100)
        input.aspectRatio = 1
        var events: [RemoteTouchInput] = []
        input.onSend = { events.append($0) }
        input.beginDrag(at: CGPoint(x: 25, y: 25))
        input.moveDrag(to: CGPoint(x: 200, y: -50))
        input.endDrag()
        input.endDrag()
        XCTAssertEqual(events.map(\.phase), [.dragBegan, .dragMoved, .dragEnded])
        XCTAssertEqual(events[1].x, 1)
        XCTAssertEqual(events[1].y, 0)
        XCTAssertEqual(Set(events.compactMap(\.gestureID)).count, 1)
        for event in events { XCTAssertNoThrow(try event.validate()) }
    }

    @MainActor
    func testDragCannotStartInBlackBarAndScrollReleasesPriorDrag() {
        let input = DirectTouchInteraction()
        input.size = CGSize(width: 100, height: 100)
        input.aspectRatio = 2
        var events: [RemoteTouchInput] = []
        input.onSend = { events.append($0) }
        input.beginDrag(at: CGPoint(x: 50, y: 10))
        input.moveDrag(to: CGPoint(x: 50, y: 50))
        XCTAssertTrue(events.isEmpty)
        input.beginDrag(at: CGPoint(x: 50, y: 50))
        input.scroll(at: CGPoint(x: 50, y: 50), translation: CGPoint(x: 10, y: -20))
        XCTAssertEqual(events.map(\.phase), [.dragBegan, .dragEnded, .scroll])
        XCTAssertEqual(events.last?.deltaX, 15)
        XCTAssertEqual(events.last?.deltaY, -30)
    }

    @MainActor
    func testStreamOrLayoutChangeReleasesGestureUsingOldCallback() {
        let view = DirectTouchView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var old: [RemoteTouchInput] = []
        var next: [RemoteTouchInput] = []
        view.configure(aspectRatio: 1, streamID: UUID(), enabled: true) { old.append($0) }
        view.layoutSubviews()
        view.interaction.beginDrag(at: CGPoint(x: 50, y: 50))
        view.configure(aspectRatio: 1, streamID: UUID(), enabled: true) { next.append($0) }
        XCTAssertEqual(old.map(\.phase), [.dragBegan, .dragEnded])
        XCTAssertTrue(next.isEmpty)
        view.interaction.beginDrag(at: CGPoint(x: 50, y: 50))
        view.frame.size = CGSize(width: 200, height: 100)
        view.layoutSubviews()
        XCTAssertEqual(next.map(\.phase), [.dragBegan, .dragEnded])
    }
}
