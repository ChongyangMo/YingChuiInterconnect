import UIKit
import XCTest
import YingchuiProtocol
@testable import YingchuiPad

final class CursorTests: XCTestCase {
    @MainActor
    static func state(position: RemoteCursorPoint = .init(x: 100, y: 100), acknowledged: UInt64 = 0,
                      withShape: Bool = true) -> RemoteCursorState {
        let data = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 30)).pngData { context in
            UIColor.black.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 30))
        }
        return RemoteCursorState(position: position,
            captureBounds: .init(x: 0, y: 0, width: 1_000, height: 500),
            displays: [.init(x: -1_000, y: 0, width: 1_000, height: 500),
                       .init(x: 0, y: 0, width: 1_000, height: 500)],
            visible: true, acknowledgedInput: acknowledged,
            shape: withShape ? .init(png: data, width: 20, height: 30, hotSpot: .init(x: 5, y: 5)) : nil)
    }

    @MainActor
    func testLateHostPositionCannotPullLocallyMovedCursorBack() throws {
        let model = PadCursorModel(), stream = UUID()
        try model.configure(streamID: stream, state: Self.state())
        let first = try XCTUnwrap(model.move(deltaX: 40, deltaY: 10))
        let second = try XCTUnwrap(model.move(deltaX: 60, deltaY: 20))
        try model.apply(Self.state(position: first.position, acknowledged: first.sequence, withShape: false), streamID: stream)
        XCTAssertEqual(model.position, second.position)
        try model.apply(Self.state(position: second.position, acknowledged: second.sequence, withShape: false), streamID: stream)
        XCTAssertEqual(model.position, .init(x: 200, y: 130))
        try model.apply(Self.state(position: .init(x: 250, y: 150), acknowledged: second.sequence, withShape: false), streamID: stream)
        XCTAssertEqual(model.position, .init(x: 250, y: 150), "Mac 本地鼠标仍可接管")
    }

    @MainActor
    func testOldStreamCannotOverwriteNewCursorAndSequencesDoNotRepeat() throws {
        let model = PadCursorModel(), old = UUID(), current = UUID()
        try model.configure(streamID: old, state: Self.state())
        let previous = try XCTUnwrap(model.move(deltaX: 1, deltaY: 0))
        try model.configure(streamID: current, state: Self.state())
        try model.apply(Self.state(position: .init(x: 800, y: 400)), streamID: old)
        XCTAssertEqual(model.position, .init(x: 100, y: 100))
        XCTAssertGreaterThan(try XCTUnwrap(model.move(deltaX: 1, deltaY: 0)).sequence, previous.sequence)
        model.reset()
        XCTAssertNil(model.position)
        XCTAssertNil(model.move(deltaX: 1, deltaY: 0))
    }

    @MainActor
    func testOverlayUsesHotspotAspectFitAndResizesWithoutChangingRemotePosition() throws {
        let model = PadCursorModel(), stream = UUID()
        try model.configure(streamID: stream, state: Self.state())
        let view = PadCursorOverlayView(frame: CGRect(x: 0, y: 0, width: 1_200, height: 800))
        model.attach(view)
        XCTAssertTrue(view.cursorLayer.isHidden, "首帧前不显示独立光标")
        model.showVideo()
        XCTAssertFalse(view.cursorLayer.isHidden)
        XCTAssertEqual(view.cursorLayer.position.x, 114, accuracy: 0.01)
        XCTAssertEqual(view.cursorLayer.bounds.width, 24, accuracy: 0.01)
        XCTAssertEqual(view.cursorLayer.superlayer?.frame.minY, 100)
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        view.refresh()
        XCTAssertEqual(view.cursorLayer.position.x, 57, accuracy: 0.01)
        XCTAssertEqual(model.position, .init(x: 100, y: 100))
        _ = model.move(deltaX: -200, deltaY: 0)
        XCTAssertEqual(model.position, .init(x: -100, y: 100))
        XCTAssertTrue(view.cursorLayer.isHidden, "光标移到另一块屏幕时隐藏投屏内光标")
    }

    @MainActor
    func testTouchAndEdgeProjectionUseMacLogicalPoints() throws {
        let model = PadCursorModel()
        try model.configure(streamID: UUID(), state: Self.state())
        let input = try XCTUnwrap(model.touch(.init(phase: .tap, x: 1, y: 1)))
        XCTAssertEqual(input.position, .init(x: 999, y: 499))
        XCTAssertEqual(model.move(deltaX: 200, deltaY: 200)?.position, input.position)
    }

    @MainActor
    func testMalformedImageAndMissingInitialShapeAreErrors() {
        let model = PadCursorModel()
        XCTAssertThrowsError(try model.configure(streamID: UUID(), state: Self.state(withShape: false)))
        let state = Self.state()
        let invalid = RemoteCursorState(position: state.position, captureBounds: state.captureBounds,
            displays: state.displays, visible: true, acknowledgedInput: 0,
            shape: .init(png: Data([1, 2, 3]), width: 20, height: 30, hotSpot: .init(x: 0, y: 0)))
        XCTAssertThrowsError(try model.configure(streamID: UUID(), state: invalid))
    }
}
