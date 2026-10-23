import UIKit
import XCTest
import YingchuiProtocol
@testable import YingchuiPad

@MainActor
final class ScrollMomentumTests: XCTestCase {
    func testSmallDeltasSurviveRoundingAndLaterMovesAreCoalesced() {
        let session = DirectTouchScrollSession()
        var moves: [CGPoint] = []
        session.onSend = { _, delta, phase in if phase == .changed { moves.append(delta) } }
        session.begin(at: CGPoint(x: 10, y: 20))
        for index in 0..<8 {
            session.move(by: CGPoint(x: 0, y: 0.25))
            session.tick(now: Double(index))
        }
        XCTAssertEqual(moves.reduce(0) { $0 + $1.y }, 3)
        let count = moves.count
        session.move(by: CGPoint(x: 0, y: 2))
        session.move(by: CGPoint(x: 0, y: 3))
        XCTAssertEqual(moves.count, count)
        session.tick(now: 9)
        XCTAssertEqual(moves.count, count + 1)
        XCTAssertEqual(moves.last?.y, 7)
    }

    func testMomentumDeceleratesAtOriginalAnchorAndTerminates() {
        let session = DirectTouchScrollSession()
        var phases: [RemoteScrollPhase] = []
        var deltas: [CGFloat] = []
        let point = CGPoint(x: 25, y: 50)
        session.onSend = { anchor, delta, phase in
            XCTAssertEqual(anchor, point)
            phases.append(phase)
            if phase == .momentumChanged { deltas.append(delta.y) }
        }
        session.begin(at: point)
        session.move(by: CGPoint(x: 0, y: 10))
        session.end(velocity: CGPoint(x: 0, y: 1000), allowsMomentum: true, now: 10)
        for tick in 1...90 { session.tick(now: 10 + Double(tick) / 60) }
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(Array(phases.prefix(4)), [.began, .changed, .ended, .momentumBegan])
        XCTAssertEqual(phases.last, .momentumEnded)
        XCTAssertGreaterThan(deltas.first ?? 0, deltas.last ?? 0)
        XCTAssertTrue(deltas.allSatisfy { $0 > 0 && $0 <= 300 })
        XCTAssertLessThan(deltas.reduce(0, +), 180)
    }

    func testCancellationDropsPendingMovementAndCannotRestartOnLaterTicks() {
        let session = DirectTouchScrollSession()
        var phases: [RemoteScrollPhase] = []
        session.onSend = { _, _, phase in phases.append(phase) }
        session.begin(at: .zero)
        session.move(by: CGPoint(x: 0, y: 10))
        session.end(velocity: CGPoint(x: 0, y: 1000), allowsMomentum: true, now: 10)
        session.tick(now: 10.02)
        session.cancel()
        let count = phases.count
        session.tick(now: 10.04)
        XCTAssertEqual(phases.count, count)
        XCTAssertEqual(phases.last, .momentumEnded)
        session.begin(at: .zero)
        session.move(by: CGPoint(x: 0, y: 10))
        session.move(by: CGPoint(x: 0, y: 100))
        session.cancel()
        XCTAssertEqual(phases.last, .cancelled)
        XCTAssertFalse(session.isActive)
    }

    func testSlowReleaseAndReducedMotionDoNotStartMomentum() {
        for (speed, allowed) in [(50.0, true), (1000.0, false)] {
            let session = DirectTouchScrollSession()
            var phases: [RemoteScrollPhase] = []
            session.onSend = { _, _, phase in phases.append(phase) }
            session.begin(at: .zero)
            session.end(velocity: CGPoint(x: 0, y: speed), allowsMomentum: allowed, now: 10)
            XCTAssertEqual(phases, [.began, .ended])
            XCTAssertFalse(session.isActive)
        }
    }

    func testMainThreadStallStopsMomentumWithoutCatchUpBurst() {
        let session = DirectTouchScrollSession()
        var phases: [RemoteScrollPhase] = []
        session.onSend = { _, _, phase in phases.append(phase) }
        session.begin(at: .zero)
        session.end(velocity: CGPoint(x: 0, y: 1000), allowsMomentum: true, now: 10)
        session.tick(now: 10.5)
        XCTAssertEqual(phases, [.began, .ended, .momentumBegan, .momentumEnded])
        XCTAssertFalse(session.isActive)
    }

    func testNewTouchStopsMomentumBeforeClickAndStreamChangeAlsoCancels() {
        let view = DirectTouchView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var events: [RemoteTouchInput] = []
        view.configure(aspectRatio: 1, streamID: UUID(), enabled: true) { events.append($0) }
        view.layoutSubviews()
        view.interaction.beginFingerScroll(at: CGPoint(x: 25, y: 50))
        view.interaction.fingerScroll.end(velocity: CGPoint(x: 0, y: 1000), allowsMomentum: true, now: 10)
        XCTAssertTrue(view.interaction.fingerScroll.isDecelerating)
        XCTAssertTrue(view.gestureRecognizer(UITapGestureRecognizer(), shouldReceive: UITouch()))
        XCTAssertFalse(view.interaction.fingerScroll.isActive)
        XCTAssertEqual(events.last?.scrollPhase, .momentumEnded)
        view.interaction.beginFingerScroll(at: CGPoint(x: 25, y: 50))
        view.interaction.fingerScroll.end(velocity: CGPoint(x: 0, y: 1000), allowsMomentum: true, now: 10)
        view.configure(aspectRatio: 1, streamID: UUID(), enabled: true) { _ in XCTFail("旧手势不能进入新画面") }
        XCTAssertFalse(view.interaction.fingerScroll.isActive)
        XCTAssertEqual(events.last?.scrollPhase, .momentumEnded)
    }
}
