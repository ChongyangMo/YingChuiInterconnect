import Foundation
import XCTest
@testable import YingchuiProtocol

final class AdaptiveVideoRepairTests: XCTestCase {
    func testRealSamplesControlBudgetAndFailuresRestoreConservativeWait() {
        var policy = AdaptiveVideoRepairPolicy()
        XCTAssertEqual(policy.waitNanoseconds, 90_000_000)
        for value in [Double.nan, .infinity, -1, 0] { policy.recordRoundTrip(milliseconds: value) }
        XCTAssertEqual(policy.waitNanoseconds, 90_000_000)
        for _ in 0..<4 { policy.recordRoundTrip(milliseconds: 14) }
        XCTAssertEqual(policy.waitNanoseconds, 40_000_000)
        for _ in 0..<3 { policy.recordRepair(milliseconds: 30) }
        XCTAssertEqual(policy.waitNanoseconds, 53_000_000)
        policy.recordFailure()
        XCTAssertEqual(policy.waitNanoseconds, 90_000_000)
        for _ in 0..<2 { policy.recordRepair(milliseconds: 30) }
        XCTAssertEqual(policy.waitNanoseconds, 90_000_000)
        policy.recordRepair(milliseconds: 30)
        XCTAssertEqual(policy.waitNanoseconds, 53_000_000)
        policy.recordRoundTrip(milliseconds: 200)
        XCTAssertEqual(policy.waitNanoseconds, 90_000_000)
    }

    func testPartialLaterFrameCanRequestRepairAfterGraceWithoutWaitingForCompletion() throws {
        let stream = UUID()
        func parts(_ id: UInt32, key: Bool = false) throws -> [VideoFragment] {
            try VideoDatagramCodec.fragment(accessUnit: Data(repeating: 1, count: 2_000), streamID: stream,
                frameID: id, presentationTimeMicroseconds: 0, isKeyFrame: key).map(VideoDatagramCodec.decode)
        }
        var buffer = VideoFrameDeliveryBuffer(repairEnabled: true, earlyRepairEnabled: true)
        let first = try parts(0, key: true), second = try parts(1), third = try parts(2)
        _ = buffer.append(first[0], now: 0); _ = buffer.append(first[1], now: 1)
        _ = buffer.append(second[0], now: 10_000_000)
        _ = buffer.append(third[0], now: 20_000_000)
        XCTAssertNil(buffer.lastAssembledFrameID)
        XCTAssertEqual(buffer.nextEarlyRepairDeadline, 24_000_000)
        XCTAssertNil(buffer.repairRequest(now: 23_999_999))
        XCTAssertEqual(buffer.repairRequest(now: 24_000_000), .init(frameID: 1, fragmentIndices: [1]))
        XCTAssertTrue(buffer.drain(now: 25_000_000).isEmpty)
        XCTAssertEqual(buffer.append(second[1], now: 30_000_000).map(\.frameID), [1])
        XCTAssertEqual(buffer.lastAssembledFrameID, 1)
        XCTAssertEqual(buffer.append(third[1], now: 31_000_000).map(\.frameID), [2])
        XCTAssertNil(buffer.nextEarlyRepairDeadline)
    }

    func testBudgetDoesNotMoveAnAlreadyWaitingGapDeadline() throws {
        let stream = UUID()
        func packet(_ id: UInt32) throws -> VideoFragment {
            try VideoDatagramCodec.decode(VideoDatagramCodec.fragment(accessUnit: Data([1]), streamID: stream,
                frameID: id, presentationTimeMicroseconds: 0, isKeyFrame: id == 0)[0])
        }
        var buffer = VideoFrameDeliveryBuffer(repairEnabled: true, earlyRepairEnabled: true)
        XCTAssertTrue(buffer.updateRepairWaitNanoseconds(40_000_000))
        _ = buffer.append(try packet(0), now: 0)
        _ = buffer.append(try packet(2), now: 20_000_000)
        XCTAssertEqual(buffer.nextDeadline, 60_000_000)
        XCTAssertFalse(buffer.updateRepairWaitNanoseconds(90_000_000))
        XCTAssertEqual(buffer.nextDeadline, 60_000_000)
        XCTAssertTrue(buffer.drain(now: 59_999_999).isEmpty)
        XCTAssertEqual(buffer.drain(now: 60_000_000).map(\.frameID), [2])
        XCTAssertEqual(buffer.lastGap?.frameID, 1)
    }

    func testEarlyRepairHandlesWraparoundAndResetWithoutInventingMissingFragments() throws {
        let stream = UUID()
        func parts(_ id: UInt32, key: Bool = false) throws -> [VideoFragment] {
            try VideoDatagramCodec.fragment(accessUnit: Data(repeating: 1, count: 2_000), streamID: stream,
                frameID: id, presentationTimeMicroseconds: 0, isKeyFrame: key).map(VideoDatagramCodec.decode)
        }
        var buffer = VideoFrameDeliveryBuffer(repairEnabled: true, earlyRepairEnabled: true)
        let key = try parts(.max - 1, key: true), newer = try parts(0)
        _ = buffer.append(key[0], now: 0); _ = buffer.append(key[1], now: 1)
        _ = buffer.append(newer[0], now: 10_000_000)
        XCTAssertEqual(buffer.repairRequest(now: 14_000_000), .init(frameID: .max, fragmentIndices: nil))
        buffer.reset()
        XCTAssertNil(buffer.nextEarlyRepairDeadline)
        XCTAssertNil(buffer.repairRequest(now: 1_000_000_000))
    }
}
