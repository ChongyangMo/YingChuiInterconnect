import XCTest
import Network
@testable import YingchuiMac

final class IdleFramePolicyTests: XCTestCase {
    func testCaptureWaitsForTransportAndPropagatesRealFailures() throws {
        XCTAssertFalse(try MacScreenStreamer.transportIsReady(.setup))
        XCTAssertFalse(try MacScreenStreamer.transportIsReady(.preparing))
        XCTAssertFalse(try MacScreenStreamer.transportIsReady(.waiting(.posix(.ENETDOWN))))
        XCTAssertTrue(try MacScreenStreamer.transportIsReady(.ready))
        XCTAssertThrowsError(try MacScreenStreamer.transportIsReady(.failed(.posix(.ECONNREFUSED))))
        XCTAssertThrowsError(try MacScreenStreamer.transportIsReady(.cancelled))
    }

    func testIdleFramesAreLimitedToOnePerSecondWithoutSuppressingChanges() {
        var policy = MacIdleFramePolicy()
        XCTAssertTrue(policy.shouldEncode(isIdle: false, hasImage: true, forceKeyFrame: false, now: 0))
        XCTAssertFalse(policy.shouldEncode(isIdle: true, hasImage: true, forceKeyFrame: false, now: 900_000_000))
        XCTAssertTrue(policy.shouldEncode(isIdle: true, hasImage: true, forceKeyFrame: false, now: 1_000_000_000))
        XCTAssertTrue(policy.shouldEncode(isIdle: false, hasImage: true, forceKeyFrame: false, now: 1_000_000_001))
    }

    func testRequestedKeyFrameCanRefreshStaticImageButCannotInventImage() {
        var policy = MacIdleFramePolicy()
        XCTAssertFalse(policy.shouldEncode(isIdle: true, hasImage: false, forceKeyFrame: true, now: 0))
        XCTAssertTrue(policy.shouldEncode(isIdle: false, hasImage: true, forceKeyFrame: false, now: 1))
        XCTAssertTrue(policy.shouldEncode(isIdle: true, hasImage: true, forceKeyFrame: true, now: 2))
    }

    func testAnimationTailRefinesAtThirtyFPSThenReturnsToIdleRate() {
        var policy = MacIdleFramePolicy()
        XCTAssertTrue(policy.shouldEncode(isIdle: false, hasImage: true, forceKeyFrame: false, now: 0))
        XCTAssertFalse(policy.shouldEncode(isIdle: true, hasImage: true, forceKeyFrame: false, now: 16_666_667))
        for index in 1...10 {
            XCTAssertTrue(policy.shouldEncode(isIdle: true, hasImage: true, forceKeyFrame: false,
                now: UInt64(index) * 33_333_334))
        }
        XCTAssertFalse(policy.shouldEncode(isIdle: true, hasImage: true, forceKeyFrame: false, now: 370_000_000))
        XCTAssertFalse(policy.shouldEncode(isIdle: true, hasImage: true, forceKeyFrame: false, now: 1_000_000_000))
        XCTAssertTrue(policy.shouldEncode(isIdle: true, hasImage: true, forceKeyFrame: false, now: 1_334_000_000))
        XCTAssertTrue(policy.shouldEncode(isIdle: false, hasImage: true, forceKeyFrame: false, now: 1_335_000_000))
        XCTAssertTrue(policy.shouldEncode(isIdle: true, hasImage: true, forceKeyFrame: false, now: 1_369_000_000))
    }

    func testOldSendCompletionCannotReleaseNewSessionBudget() {
        let streamer = MacScreenStreamer()
        let old = streamer.captureGeneration
        streamer.captureGeneration = UUID()
        streamer.outstandingDatagrams = 10
        streamer.didCompleteDatagram(error: nil, generation: old)
        XCTAssertEqual(streamer.outstandingDatagrams, 10)
        streamer.didCompleteDatagram(error: nil, generation: streamer.captureGeneration)
        XCTAssertEqual(streamer.outstandingDatagrams, 9)
    }
}
