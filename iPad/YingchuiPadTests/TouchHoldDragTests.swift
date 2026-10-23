import UIKit
import XCTest
import YingchuiProtocol
@testable import YingchuiPad

final class TouchHoldDragTests: XCTestCase {
    @MainActor
    func testHoldingThenDraggingSidebarKeepsOriginalAnchorAndReleasesAtDropPoint() throws {
        let input = DirectTouchInteraction()
        input.size = CGSize(width: 1000, height: 750)
        input.aspectRatio = 4.0 / 3
        var events: [RemoteTouchInput] = []
        input.onSend = { events.append($0) }
        input.beginHold(at: CGPoint(x: 100, y: 150))
        input.moveHold(to: CGPoint(x: 102, y: 151))
        XCTAssertEqual(events.map(\.phase), [.hover], "手指抖动不能误触发拖拽")
        input.moveHold(to: CGPoint(x: 100, y: 175))
        input.moveHold(to: CGPoint(x: 100, y: 300))
        input.endHold(at: CGPoint(x: 100, y: 375))
        XCTAssertEqual(events.map(\.phase), [.hover, .dragBegan, .dragMoved, .dragMoved, .dragMoved, .dragEnded])
        XCTAssertEqual(events[1].x, 0.1)
        XCTAssertEqual(events[1].y, 0.2, "必须在原项目上按下，不能在移动后的其他项目上按下")
        XCTAssertEqual(events.last?.y, 0.5)
        XCTAssertEqual(Set(events.compactMap(\.gestureID)).count, 1)
        for event in events { XCTAssertNoThrow(try event.validate()) }
    }

    @MainActor
    func testStationaryHoldStillOpensHoverMenuWithoutClicking() {
        let input = DirectTouchInteraction()
        input.size = CGSize(width: 100, height: 100)
        input.aspectRatio = 1
        var phases: [RemoteTouchPhase] = []
        input.onSend = { phases.append($0.phase) }
        input.beginHold(at: CGPoint(x: 25, y: 25))
        input.moveHold(to: CGPoint(x: 28, y: 27))
        input.endHold(at: CGPoint(x: 28, y: 27))
        XCTAssertEqual(phases, [.hover])
        input.tap(at: CGPoint(x: 25, y: 50))
        XCTAssertEqual(phases, [.hover, .tap])
    }

    @MainActor
    func testScrollCancelsHeldDragAndLateMovementCannotRestartIt() {
        let input = DirectTouchInteraction()
        input.size = CGSize(width: 100, height: 100)
        input.aspectRatio = 1
        var events: [RemoteTouchInput] = []
        input.onSend = { events.append($0) }
        input.beginHold(at: CGPoint(x: 25, y: 25))
        input.moveHold(to: CGPoint(x: 75, y: 25))
        input.scroll(at: CGPoint(x: 75, y: 25), translation: CGPoint(x: 0, y: 10))
        input.moveHold(to: CGPoint(x: 90, y: 90))
        input.endHold()
        XCTAssertEqual(events.map(\.phase), [.hover, .dragBegan, .dragMoved, .dragEnded, .scroll])
    }

    @MainActor
    func testStreamChangeReleasesHeldDragThroughOldCallbackExactlyOnce() {
        let view = DirectTouchView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var old: [RemoteTouchInput] = []
        var next: [RemoteTouchInput] = []
        view.configure(aspectRatio: 1, streamID: UUID(), enabled: true) { old.append($0) }
        view.layoutSubviews()
        view.interaction.beginHold(at: CGPoint(x: 25, y: 25))
        view.interaction.moveHold(to: CGPoint(x: 75, y: 25))
        view.configure(aspectRatio: 1, streamID: UUID(), enabled: true) { next.append($0) }
        view.interaction.moveHold(to: CGPoint(x: 90, y: 25))
        view.interaction.endHold()
        XCTAssertEqual(old.map(\.phase), [.hover, .dragBegan, .dragMoved, .dragEnded])
        XCTAssertTrue(next.isEmpty)
    }

    @MainActor
    func testLongDragOutsideVideoClampsAndBlackBarCannotStartHold() {
        let input = DirectTouchInteraction()
        input.size = CGSize(width: 100, height: 100)
        input.aspectRatio = 2
        var events: [RemoteTouchInput] = []
        input.onSend = { events.append($0) }
        input.beginHold(at: CGPoint(x: 50, y: 10))
        input.moveHold(to: CGPoint(x: 50, y: 50))
        XCTAssertTrue(events.isEmpty)
        input.beginHold(at: CGPoint(x: 25, y: 50))
        input.moveHold(to: CGPoint(x: 200, y: -50))
        input.endHold()
        XCTAssertEqual(events.last?.x, 1)
        XCTAssertEqual(events.last?.y, 0)
        XCTAssertEqual(events.last?.phase, .dragEnded)
    }

    @MainActor
    func testBackgroundingReleasesBothTouchAndTrackpadOnce() {
        let touch = DirectTouchView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var events: [RemoteTouchInput] = []
        touch.configure(aspectRatio: 1, streamID: UUID(), enabled: true) { events.append($0) }
        touch.layoutSubviews()
        touch.interaction.beginHold(at: CGPoint(x: 25, y: 25))
        touch.interaction.moveHold(to: CGPoint(x: 75, y: 25))
        let trackpad = RemoteGestureView()
        var pressed: [Bool] = []
        trackpad.onDragChanged = { pressed.append($0) }
        trackpad.beginDraggingIfNeeded()
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        touch.cancelInteraction()
        trackpad.finishDraggingIfNeeded()
        XCTAssertEqual(events.filter { $0.phase == .dragEnded }.count, 1)
        XCTAssertEqual(pressed, [true, false])
    }

    @MainActor
    func testTrackpadStreamChangeAndDisableReleaseButton() {
        let view = RemoteGestureView()
        var pressed: [Bool] = []
        view.onDragChanged = { pressed.append($0) }
        view.configure(streamID: UUID(), enabled: true)
        view.beginDraggingIfNeeded()
        view.configure(streamID: UUID(), enabled: true)
        view.beginDraggingIfNeeded()
        view.configure(streamID: nil, enabled: false)
        view.beginDraggingIfNeeded()
        XCTAssertEqual(pressed, [true, false, true, false])
    }
}
