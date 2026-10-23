import XCTest
@testable import YingchuiPad

final class InteractionPresentationTests: XCTestCase {
    func testOnlyFirstFrameAfterQuietInteractionCanSkipApplicationClock() {
        var policy = PadInteractionPresentationPolicy()
        XCTAssertFalse(policy.consumeFrame(now: 0, hasPendingPictures: false))
        policy.prepare(now: 200_000_000)
        XCTAssertTrue(policy.consumeFrame(now: 240_000_000, hasPendingPictures: false))
        XCTAssertFalse(policy.consumeFrame(now: 257_000_000, hasPendingPictures: false))
        policy.prepare(now: 258_000_000)
        XCTAssertFalse(policy.consumeFrame(now: 274_000_000, hasPendingPictures: false))
    }

    func testPendingOlderPicturesPreventOutOfOrderDirectPresentation() {
        var policy = PadInteractionPresentationPolicy()
        _ = policy.consumeFrame(now: 0, hasPendingPictures: false)
        policy.prepare(now: 200_000_000)
        XCTAssertFalse(policy.consumeFrame(now: 220_000_000, hasPendingPictures: true))
        XCTAssertFalse(policy.consumeFrame(now: 237_000_000, hasPendingPictures: false))
    }

    func testExpiredAndBackwardTimeNeverLeaveADeferredBypass() {
        var policy = PadInteractionPresentationPolicy()
        _ = policy.consumeFrame(now: 0, hasPendingPictures: false)
        policy.prepare(now: 200_000_000)
        XCTAssertFalse(policy.consumeFrame(now: 450_000_001, hasPendingPictures: false))
        policy.prepare(now: 650_000_000)
        XCTAssertFalse(policy.consumeFrame(now: 640_000_000, hasPendingPictures: false))
        XCTAssertFalse(policy.consumeFrame(now: 660_000_000, hasPendingPictures: false))
    }
}
