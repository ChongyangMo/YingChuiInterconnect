import UIKit
import XCTest
import YingchuiProtocol
@testable import YingchuiPad

final class FingerScrollTests: XCTestCase {
    @MainActor
    func testFingerPanSendsIncrementalScrollAtOriginalTargetWithoutMouseDownOrTap() {
        let interaction = DirectTouchInteraction()
        interaction.size = CGSize(width: 100, height: 100)
        interaction.aspectRatio = 1
        var events: [RemoteTouchInput] = []
        interaction.onSend = { events.append($0) }
        interaction.beginFingerScroll(at: CGPoint(x: 25, y: 50))
        interaction.moveFingerScroll(by: CGPoint(x: 0, y: 10))
        interaction.moveFingerScroll(by: CGPoint(x: 0, y: 5))
        interaction.tap(at: CGPoint(x: 50, y: 50))
        interaction.endFingerScroll()
        interaction.moveFingerScroll(by: CGPoint(x: 0, y: 10))
        XCTAssertEqual(events.map(\.scrollPhase), [.began, .changed, .changed, .ended])
        XCTAssertEqual(events.map(\.deltaY), [0, 15, 7, 0])
        XCTAssertTrue(events.allSatisfy { $0.phase == .scroll })
        XCTAssertTrue(events.allSatisfy { $0.x == 0.25 && $0.y == 0.5 && $0.gestureID == nil })
    }

    @MainActor
    func testHeldDragHasPriorityAndGestureCancellationAllowsNextTap() {
        let interaction = DirectTouchInteraction()
        interaction.size = CGSize(width: 100, height: 100)
        interaction.aspectRatio = 1
        var events: [RemoteTouchInput] = []
        interaction.onSend = { events.append($0) }
        interaction.beginHold(at: CGPoint(x: 20, y: 30))
        interaction.moveHold(to: CGPoint(x: 20, y: 50))
        interaction.beginFingerScroll(at: CGPoint(x: 20, y: 50))
        interaction.moveFingerScroll(by: CGPoint(x: 0, y: 10))
        interaction.endHold()
        XCTAssertEqual(events.map(\.phase), [.hover, .dragBegan, .dragMoved, .dragEnded])
        interaction.beginFingerScroll(at: CGPoint(x: 20, y: 50))
        interaction.endFingerScroll()
        interaction.tap(at: CGPoint(x: 20, y: 50))
        XCTAssertEqual(events.last?.phase, .tap)
    }

    @MainActor
    func testStreamChangeCancelsFingerScrollAndFingerAndPencilHaveSeparateRecognizers() throws {
        let view = DirectTouchView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var old: [RemoteTouchInput] = []
        var next: [RemoteTouchInput] = []
        view.configure(aspectRatio: 1, streamID: UUID(), enabled: true) { old.append($0) }
        view.layoutSubviews()
        view.interaction.beginFingerScroll(at: CGPoint(x: 20, y: 50))
        view.interaction.moveFingerScroll(by: CGPoint(x: 0, y: 10))
        view.configure(aspectRatio: 1, streamID: UUID(), enabled: true) { next.append($0) }
        view.interaction.moveFingerScroll(by: CGPoint(x: 0, y: 10))
        XCTAssertEqual(old.map(\.scrollPhase), [.began, .changed, .cancelled])
        XCTAssertTrue(next.isEmpty)
        let pans = (view.gestureRecognizers ?? []).compactMap { $0 as? UIPanGestureRecognizer }
        XCTAssertEqual(pans.filter { $0.maximumNumberOfTouches == 1 && $0.allowedTouchTypes == [NSNumber(value: UITouch.TouchType.direct.rawValue)] }.count, 1)
        XCTAssertEqual(pans.filter { $0.maximumNumberOfTouches == 1 && $0.allowedTouchTypes == [NSNumber(value: UITouch.TouchType.pencil.rawValue)] }.count, 1)
        view.previewNavigation = true
        XCTAssertFalse(try XCTUnwrap(pans.first { $0.minimumNumberOfTouches == 2 }).isEnabled)
    }
}
