import XCTest
@testable import YingchuiProtocol

final class NetworkLossFeedbackTests: XCTestCase {
    func testRecoveryDiscardDoesNotTriggerRepeatedNetworkBitrateReduction() throws {
        var tracker = StreamStatisticsTracker()
        XCTAssertNil(try tracker.lossRate(decoded: 0, dropped: 0, networkMissing: 0))
        let loss = try XCTUnwrap(tracker.lossRate(decoded: 60, dropped: 40, networkMissing: 1))
        XCTAssertEqual(loss, 1.0 / 61, accuracy: 0.0001)
        var bitrate = AdaptiveBitRatePolicy(maximumBitRate: 12_000_000)
        XCTAssertNil(bitrate.evaluate(lossRate: loss))
        XCTAssertEqual(bitrate.currentBitRate, 12_000_000)
    }

    func testRealNetworkLossStillReducesBitrate() throws {
        var tracker = StreamStatisticsTracker()
        _ = try tracker.lossRate(decoded: 0, dropped: 0, networkMissing: 0)
        let loss = try XCTUnwrap(tracker.lossRate(decoded: 50, dropped: 30, networkMissing: 10))
        var bitrate = AdaptiveBitRatePolicy(maximumBitRate: 12_000_000)
        XCTAssertEqual(bitrate.evaluate(lossRate: loss), 9_000_000)
    }

    func testOlderPeersAndInvalidCountersRemainExplicit() throws {
        var tracker = StreamStatisticsTracker()
        _ = try tracker.lossRate(decoded: 0, dropped: 0)
        XCTAssertEqual(try tracker.lossRate(decoded: 60, dropped: 40), 0.4)
        XCTAssertThrowsError(try tracker.lossRate(decoded: 100, dropped: 10, networkMissing: 11))
    }

    func testNetworkCounterRoundTripsWithoutRequiringNewProtocolVersion() throws {
        let message = WireMessage(kind: .streamStats, framesDecoded: 100, framesDropped: 40, networkFramesMissing: 1)
        XCTAssertEqual(try JSONDecoder().decode(WireMessage.self, from: JSONEncoder().encode(message)), message)
        let old = WireMessage(kind: .streamStats, framesDecoded: 100, framesDropped: 40)
        XCTAssertNil(try JSONDecoder().decode(WireMessage.self, from: JSONEncoder().encode(old)).networkFramesMissing)
    }
}
