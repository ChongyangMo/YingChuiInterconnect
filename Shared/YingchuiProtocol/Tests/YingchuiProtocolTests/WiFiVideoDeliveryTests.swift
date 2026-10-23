import Foundation
import XCTest
@testable import YingchuiProtocol

final class WiFiVideoDeliveryTests: XCTestCase {
    private let stream = UUID()
    private func fragments(_ id: UInt32, key: Bool = false, size: Int = 10) throws -> [VideoFragment] {
        try VideoDatagramCodec.fragment(accessUnit: Data(repeating: 7, count: size), streamID: stream,
            frameID: id, presentationTimeMicroseconds: UInt64(id), isKeyFrame: key)
            .map(VideoDatagramCodec.decode)
    }

    func testOutOfOrderFrameWaitsForEarlierIncompleteFrame() throws {
        var buffer = VideoFrameDeliveryBuffer()
        XCTAssertEqual(buffer.append(try fragments(1, key: true)[0], now: 0).map(\.frameID), [1])
        let second = try fragments(2, size: 2_000)
        XCTAssertTrue(buffer.append(second[0], now: 1).isEmpty)
        XCTAssertTrue(buffer.append(try fragments(3)[0], now: 2).isEmpty)
        XCTAssertEqual(buffer.nextDeadline, 30_000_002)
        // 副本不能重置等待期限，也不能阻止较旧帧组装。
        XCTAssertTrue(buffer.append(try fragments(3)[0], now: 20_000_000).isEmpty)
        XCTAssertEqual(buffer.nextDeadline, 30_000_002)
        XCTAssertEqual(buffer.append(second[1], now: 25_000_000).map(\.frameID), [2, 3])
        XCTAssertNil(buffer.nextDeadline)
        XCTAssertEqual(buffer.discardIncompleteFrames(olderThanUptimeNanoseconds: 1_000_000_000), 0)
    }

    func testRealGapExpiresWithoutWaitingForAnotherPacket() throws {
        var buffer = VideoFrameDeliveryBuffer()
        _ = buffer.append(try fragments(1, key: true)[0], now: 0)
        XCTAssertTrue(buffer.append(try fragments(3)[0], now: 10).isEmpty)
        XCTAssertTrue(buffer.drain(now: 30_000_009).isEmpty)
        XCTAssertEqual(buffer.drain(now: 30_000_010).map(\.frameID), [3])
        XCTAssertTrue(buffer.append(try fragments(2)[0], now: 40_000_000).isEmpty)
    }

    func testGapDiagnosisDistinguishesMissingFragmentsFromEntireMissingFrame() throws {
        var buffer = VideoFrameDeliveryBuffer()
        _ = buffer.append(try fragments(1, key: true)[0], now: 0)
        let second = try fragments(2, size: 3_000)
        _ = buffer.append(second[0], now: 1)
        _ = buffer.append(try fragments(3)[0], now: 2)
        _ = buffer.drain(now: 30_000_002)
        XCTAssertEqual(buffer.lastGap?.frameID, 2)
        XCTAssertEqual(buffer.lastGap?.missingFragments, [1, 2])
        XCTAssertEqual(buffer.lastGap?.declaredAt, 30_000_002)
        _ = buffer.append(try fragments(4, key: true)[0], now: 40_000_000)
        _ = buffer.append(try fragments(6)[0], now: 40_000_001)
        _ = buffer.drain(now: 70_000_001)
        XCTAssertEqual(buffer.lastGap?.frameID, 5)
        XCTAssertNil(buffer.lastGap?.missingFragments)
        buffer.reset()
        XCTAssertNil(buffer.lastGap)
    }

    func testKeyFrameBypassesGapAndCleansExpiredFragments() throws {
        var buffer = VideoFrameDeliveryBuffer()
        _ = buffer.append(try fragments(1, key: true)[0], now: 0)
        _ = buffer.append(try fragments(2, size: 2_000)[0], now: 1)
        _ = buffer.append(try fragments(3)[0], now: 2)
        XCTAssertEqual(buffer.append(try fragments(4, key: true)[0], now: 3).map(\.frameID), [4])
        XCTAssertEqual(buffer.discardIncompleteFrames(olderThanUptimeNanoseconds: 100), 0)
        XCTAssertNil(buffer.nextDeadline)
    }

    func testWraparoundAndResetRemainOrdered() throws {
        var buffer = VideoFrameDeliveryBuffer()
        _ = buffer.append(try fragments(UInt32.max - 1, key: true)[0], now: 0)
        XCTAssertTrue(buffer.append(try fragments(0)[0], now: 1).isEmpty)
        XCTAssertEqual(buffer.append(try fragments(UInt32.max)[0], now: 2).map(\.frameID), [UInt32.max, 0])
        _ = buffer.append(try fragments(2)[0], now: 3)
        buffer.reset()
        XCTAssertNil(buffer.nextDeadline)
        XCTAssertTrue(buffer.drain(now: 1_000_000_000).isEmpty)
        XCTAssertEqual(buffer.append(try fragments(0, key: true)[0], now: 4).map(\.frameID), [0])
    }

    func testPendingFrameLimitForcesGapInsteadOfGrowingLatency() throws {
        var buffer = VideoFrameDeliveryBuffer(maximumPendingFrames: 3)
        _ = buffer.append(try fragments(1, key: true)[0], now: 0)
        _ = buffer.append(try fragments(3)[0], now: 1)
        _ = buffer.append(try fragments(4)[0], now: 2)
        XCTAssertEqual(buffer.append(try fragments(5)[0], now: 3).map(\.frameID), [3])
        XCTAssertNil(buffer.nextDeadline)
    }

    func testExpiredGapDoesNotLetQueuedDeltaInvalidateIncompleteRecoveryKey() throws {
        var buffer = VideoFrameDeliveryBuffer()
        _ = buffer.append(try fragments(1, key: true)[0], now: 0)
        _ = buffer.append(try fragments(3)[0], now: 1)
        let replacement = try fragments(4, key: true, size: 2_000)
        _ = buffer.append(replacement[0], now: 2)
        _ = buffer.append(try fragments(5)[0], now: 3)
        XCTAssertEqual(buffer.drain(now: 30_000_001).map(\.frameID), [3])
        XCTAssertEqual(buffer.append(replacement[1], now: 40_000_000).map(\.frameID), [4, 5])
        XCTAssertEqual(buffer.append(try fragments(6, key: true)[0], now: 40_000_001).map(\.frameID), [6])
    }

    func testWirelessReceiverHintRoundTripsAndOlderPeersRemainDecodable() throws {
        let message = WireMessage(kind: .streamStart, receiverUsesWiFi: true)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(WireMessage.self, from: encoder.encode(message)).receiverUsesWiFi, true)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(message)) as? [String: Any])
        legacy.removeValue(forKey: "receiverUsesWiFi")
        XCTAssertNil(try decoder.decode(WireMessage.self, from: JSONSerialization.data(withJSONObject: legacy)).receiverUsesWiFi)
    }

    func testWirelessStartsConservativelyAndCanRecoverToConfiguredQuality() {
        let floor = VideoBitRateFloorPolicy.minimumBitRate(dimensions: StreamDimensions(width: 2224, height: 1668),
            frameRate: 60, maximumBitRate: 30_000_000, constrainedNetwork: true)
        XCTAssertEqual(floor, 4_000_000)
        var policy = AdaptiveBitRatePolicy(maximumBitRate: 30_000_000)
        policy.reset(maximumBitRate: 30_000_000, minimumBitRate: floor, initialBitRate: 12_000_000)
        XCTAssertEqual(policy.currentBitRate, 12_000_000)
        for _ in 0..<10 { _ = policy.evaluate(lossRate: 0.1) }
        XCTAssertEqual(policy.currentBitRate, 4_000_000)
        for _ in 0..<160 { _ = policy.evaluate(lossRate: 0) }
        XCTAssertEqual(policy.currentBitRate, 30_000_000)
        policy.reset(maximumBitRate: 6_000_000, minimumBitRate: floor, initialBitRate: 12_000_000)
        XCTAssertEqual(policy.currentBitRate, 6_000_000)
    }
}
