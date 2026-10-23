import XCTest
@testable import YingchuiProtocol

final class PeerClockEstimatorTests: XCTestCase {
    func testDelayedRepliesDoNotPullOffsetAwayFromLowRoundTripSample() throws {
        var estimator = PeerClockEstimator()
        estimator.record(sentWallMilliseconds: 1_000, receivedWallMilliseconds: 1_020,
            peerWallMilliseconds: 1_020, roundTripMilliseconds: 20, receivedAtUptime: 1)
        estimator.record(sentWallMilliseconds: 2_000, receivedWallMilliseconds: 2_400,
            peerWallMilliseconds: 2_500, roundTripMilliseconds: 400, receivedAtUptime: 1_000_000_001)
        XCTAssertEqual(try XCTUnwrap(estimator.estimate).offsetMilliseconds, 10)
        XCTAssertEqual(estimator.estimate?.minimumRoundTripMilliseconds, 20)
        XCTAssertEqual(estimator.estimate?.sampleCount, 2)
    }

    func testOldSamplesExpireAndStorageRemainsBounded() throws {
        var estimator = PeerClockEstimator()
        estimator.record(sentWallMilliseconds: 1_000, receivedWallMilliseconds: 1_010,
            peerWallMilliseconds: 1_015, roundTripMilliseconds: 10, receivedAtUptime: 0)
        for index in 1...20 {
            estimator.record(sentWallMilliseconds: 2_000, receivedWallMilliseconds: 2_040,
                peerWallMilliseconds: 2_120, roundTripMilliseconds: 40, receivedAtUptime: UInt64(index))
        }
        XCTAssertEqual(estimator.estimate?.sampleCount, 16)
        XCTAssertEqual(estimator.estimate?.offsetMilliseconds, 100)
        estimator.record(sentWallMilliseconds: 3_000, receivedWallMilliseconds: 3_050,
            peerWallMilliseconds: 3_225, roundTripMilliseconds: 50, receivedAtUptime: 31_000_000_000)
        XCTAssertEqual(estimator.estimate?.sampleCount, 1)
        XCTAssertEqual(estimator.estimate?.offsetMilliseconds, 200)
        estimator.record(sentWallMilliseconds: 4_000, receivedWallMilliseconds: 4_020,
            peerWallMilliseconds: 4_020, roundTripMilliseconds: .nan, receivedAtUptime: 62_000_000_000)
        XCTAssertNil(estimator.estimate)
    }

    func testWallClockJumpClearsStaleEstimateAndNextValidReplyRestoresIt() {
        var estimator = PeerClockEstimator()
        estimator.record(sentWallMilliseconds: 1_000, receivedWallMilliseconds: 1_020,
            peerWallMilliseconds: 1_020, roundTripMilliseconds: 20, receivedAtUptime: 1)
        estimator.record(sentWallMilliseconds: 2_000, receivedWallMilliseconds: 5_020,
            peerWallMilliseconds: 2_020, roundTripMilliseconds: 20, receivedAtUptime: 2)
        XCTAssertNil(estimator.estimate)
        estimator.record(sentWallMilliseconds: 6_000, receivedWallMilliseconds: 6_020,
            peerWallMilliseconds: 6_030, roundTripMilliseconds: 20, receivedAtUptime: 3)
        XCTAssertEqual(estimator.estimate?.offsetMilliseconds, 20)
        estimator.reset()
        XCTAssertNil(estimator.estimate)
    }

    func testInvalidRoundTripsAreIgnoredWithoutInventingAnEstimate() {
        var estimator = PeerClockEstimator()
        for value in [Double.nan, .infinity, -1, 0, 2_000] {
            estimator.record(sentWallMilliseconds: 1_000, receivedWallMilliseconds: 1_020,
                peerWallMilliseconds: 1_020, roundTripMilliseconds: value, receivedAtUptime: 1)
        }
        XCTAssertNil(estimator.estimate)
    }
}
