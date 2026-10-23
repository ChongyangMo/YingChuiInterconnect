import XCTest
@testable import YingchuiPad

final class ReceiveTimingTests: XCTestCase {
    func testAssemblyAndOrderedDeliveryRemainSeparateAndUnknownSystemTimeStaysUnknown() throws {
        var tracker = PadFrameReceiveTimingTracker()
        tracker.packet(1, callbackAt: 100, systemReceiveAt: nil)
        tracker.packet(1, callbackAt: 120, systemReceiveAt: 110)
        tracker.assembled(1, now: 130)
        let timing = try XCTUnwrap(tracker.delivered(1, now: 180))
        XCTAssertEqual(timing.firstCallback, 100)
        XCTAssertNil(timing.firstSystemReceive)
        XCTAssertEqual(timing.maximumCallbackDelay, 10)
        XCTAssertEqual(timing.assembledAt, 130)
        XCTAssertEqual(timing.deliveredAt, 180)
        XCTAssertNil(tracker.delivered(1, now: 190))
        tracker.packet(2, callbackAt: 200, systemReceiveAt: nil)
        let unknown = try XCTUnwrap(tracker.delivered(2, now: 210))
        XCTAssertNil(unknown.firstSystemReceive)
        XCTAssertNil(unknown.maximumCallbackDelay)
        XCTAssertNil(unknown.assembledAt)
    }
}
