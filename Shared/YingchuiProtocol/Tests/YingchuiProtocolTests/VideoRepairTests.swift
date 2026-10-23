import XCTest
@testable import YingchuiProtocol

final class VideoRepairTests: XCTestCase {
    func testOnlyMissingEncryptedPacketsAreReplayedOnce() {
        var cache = VideoRepairCache()
        let packets = (0..<5).map { Data([UInt8($0)]) }
        cache.store(frameID: 12, packets: packets, now: 100)
        let request = VideoRepairRequest(frameID: 12, fragmentIndices: [3, 1])
        XCTAssertEqual(cache.take(request, now: 101), [packets[1], packets[3]])
        XCTAssertNil(cache.take(request, now: 102))
    }

    func testCacheBoundsExpiryAndResetPreventStaleRecovery() {
        var cache = VideoRepairCache(maximumBytes: 10, maximumFrames: 2)
        cache.store(frameID: 1, packets: [Data(count: 6)], now: 10)
        cache.store(frameID: 2, packets: [Data(count: 6)], now: 20)
        XCTAssertEqual(cache.byteCount, 6)
        XCTAssertEqual(cache.frameCount, 1)
        XCTAssertNil(cache.take(.init(frameID: 1, fragmentIndices: nil), now: 21))
        XCTAssertNil(cache.take(.init(frameID: 2, fragmentIndices: nil), now: 500_000_021))
        XCTAssertEqual(cache.byteCount, 0)
        cache.store(frameID: .max, packets: [Data([1])], now: 600_000_000)
        cache.store(frameID: 0, packets: [Data([2])], now: 600_000_001)
        XCTAssertEqual(cache.take(.init(frameID: 0, fragmentIndices: nil), now: 600_000_002), [Data([2])])
        cache.reset()
        XCTAssertEqual(cache.byteCount, 0)
        XCTAssertNil(cache.take(.init(frameID: .max, fragmentIndices: nil), now: 600_000_003))
    }

    func testMalformedAndOversizedRepairDoesNotAmplifyTraffic() {
        XCTAssertFalse(VideoRepairRequest(frameID: 1, fragmentIndices: []).isValid)
        XCTAssertFalse(VideoRepairRequest(frameID: 1, fragmentIndices: [1, 1]).isValid)
        XCTAssertFalse(VideoRepairRequest(frameID: 1, fragmentIndices: [.max]).isValid)
        XCTAssertFalse(VideoRepairRequest(frameID: 1, fragmentIndices: Array(0...256)).isValid)
        var cache = VideoRepairCache()
        cache.store(frameID: 1, packets: Array(repeating: Data([1]), count: 300), now: 10)
        XCTAssertNil(cache.take(.init(frameID: 1, fragmentIndices: nil), now: 11))
        XCTAssertNil(cache.take(.init(frameID: 1, fragmentIndices: [300]), now: 12))
        XCTAssertEqual(cache.take(.init(frameID: 1, fragmentIndices: [299]), now: 13), [Data([1])])
    }

    func testRepairNegotiationRemainsCompatibleWithExistingControlMessages() throws {
        let message = WireMessage(kind: .keyframeRequest, streamID: UUID(),
            supportsVideoRepair: true, videoRepair: .init(frameID: 42, fragmentIndices: [2, 5]))
        XCTAssertEqual(try JSONDecoder().decode(WireMessage.self, from: JSONEncoder().encode(message)), message)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        object.removeValue(forKey: "supportsVideoRepair"); object.removeValue(forKey: "videoRepair")
        let old = try JSONDecoder().decode(WireMessage.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.supportsVideoRepair); XCTAssertNil(old.videoRepair)
    }

    func testMissingFragmentRepairsReferenceChainBeforeDeadlineWithoutDelayingNormalFrames() throws {
        let stream = UUID()
        func fragments(_ id: UInt32) throws -> [VideoFragment] {
            try VideoDatagramCodec.fragment(accessUnit: Data(repeating: UInt8(id), count: 2000),
                streamID: stream, frameID: id, presentationTimeMicroseconds: UInt64(id) * 16_667,
                isKeyFrame: id == 0).map { try VideoDatagramCodec.decode($0) }
        }
        var buffer = VideoFrameDeliveryBuffer(maximumPendingFrames: 12, repairEnabled: true)
        let first = try fragments(0), second = try fragments(1), third = try fragments(2)
        XCTAssertTrue(buffer.append(first[0], now: 0).isEmpty)
        XCTAssertEqual(buffer.append(first[1], now: 1).map(\.frameID), [0])
        XCTAssertNil(buffer.pendingRepairRequest)
        XCTAssertTrue(buffer.append(second[0], now: 16_000_000).isEmpty)
        XCTAssertTrue(buffer.append(third[0], now: 33_000_000).isEmpty)
        XCTAssertTrue(buffer.append(third[1], now: 34_000_000).isEmpty)
        XCTAssertEqual(buffer.pendingRepairRequest, .init(frameID: 1, fragmentIndices: [1]))
        XCTAssertTrue(buffer.drain(now: 70_000_000).isEmpty)
        XCTAssertEqual(buffer.append(second[1], now: 75_000_000).map(\.frameID), [1, 2])
        XCTAssertNil(buffer.lastGap)
        XCTAssertNil(buffer.pendingRepairRequest)
        XCTAssertNil(buffer.nextDeadline)
    }

    func testFailedRepairStillDeclaresGapWithinBoundedTime() throws {
        var buffer = VideoFrameDeliveryBuffer(repairEnabled: true)
        let stream = UUID()
        func packet(_ id: UInt32) throws -> VideoFragment {
            try VideoDatagramCodec.decode(VideoDatagramCodec.fragment(accessUnit: Data([1]),
                streamID: stream, frameID: id, presentationTimeMicroseconds: 0, isKeyFrame: id == 0)[0])
        }
        XCTAssertEqual(buffer.append(try packet(0), now: 0).count, 1)
        XCTAssertTrue(buffer.append(try packet(2), now: 10_000_000).isEmpty)
        XCTAssertEqual(buffer.pendingRepairRequest, .init(frameID: 1, fragmentIndices: nil))
        XCTAssertTrue(buffer.drain(now: 99_000_000).isEmpty)
        XCTAssertEqual(buffer.drain(now: 100_000_000).map(\.frameID), [2])
        XCTAssertEqual(buffer.lastGap?.frameID, 1)
        XCTAssertNil(buffer.pendingRepairRequest)
    }
}
