import Foundation
import XCTest
@testable import YingchuiProtocol

final class RemoteCursorTests: XCTestCase {
    func testNegotiationAndAbsoluteInputRoundTrip() throws {
        let stream = UUID(), input = RemoteCursorInput(position: .init(x: -640, y: 120), sequence: 42)
        let message = WireMessage(kind: .pointerMove, streamID: stream, cursorInput: input)
        var decoder = WireMessageDecoder()
        let decoded = try XCTUnwrap(decoder.append(WireCodec.encode(message)).first)
        XCTAssertEqual(try RemoteControlValidator.command(from: decoded), .cursorMove(input))
        XCTAssertEqual(RemoteCursorInput.sequence(fromEventTag: input.eventTag), 42)
        XCTAssertNil(RemoteCursorInput.sequence(fromEventTag: 42))
        XCTAssertThrowsError(try RemoteControlValidator.command(from: WireMessage(kind: .pointerMove, cursorInput: input)))
    }

    func testOldProtocolMessageDoesNotEnableSeparatedCursor() throws {
        let message = WireMessage(kind: .streamStart)
        let decoded = try JSONDecoder().decode(WireMessage.self, from: JSONEncoder().encode(message))
        XCTAssertNil(decoded.supportsCursor)
        XCTAssertNil(decoded.cursorState)
        XCTAssertEqual(try RemoteControlValidator.command(from: .init(kind: .pointerMove, deltaX: 5, deltaY: 6)),
                       .pointerMove(deltaX: 5, deltaY: 6))
    }

    func testCoordinatesCannotUseNaNOrOverflowAndDesktopGapsProjectToNearestScreen() {
        XCTAssertFalse(RemoteCursorInput(position: .init(x: .nan, y: 0), sequence: 1).isValid)
        XCTAssertFalse(RemoteCursorInput(position: .init(x: 0, y: 0), sequence: UInt64.max).isValid)
        let displays = [RemoteCursorRect(x: -1_000, y: 0, width: 1_000, height: 600),
                        RemoteCursorRect(x: 0, y: 200, width: 1_000, height: 600)]
        XCTAssertEqual(RemoteCursorRect.project(.init(x: 30, y: 50), onto: displays), .init(x: -1, y: 50))
        XCTAssertNil(RemoteCursorRect.project(.init(x: 0, y: 0), onto: []))
    }
}
