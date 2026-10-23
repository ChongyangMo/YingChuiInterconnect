import Foundation
import XCTest
@testable import YingchuiMac

final class VideoDatagramPacerTests: XCTestCase {
    func testLargeFrameFirstCopyKeepsSmallBatchesAndAllReplicas() async {
        let queue = DispatchQueue(label: "大帧发送顺序测试")
        let pacer = MacVideoDatagramPacer(queue: queue)
        let done = expectation(description: "大帧小批发送且副本完整")
        queue.async {
            pacer.acceleratesLargeFrames = true
            var output: [UInt8] = []
            pacer.enqueue((0..<96).map { Data([UInt8($0)]) }, copies: 2) { batch in
                XCTAssertLessThanOrEqual(batch.count, 8)
                output += batch.map { $0[0] }
                if output.count == 192 {
                    XCTAssertEqual(output, Array(0..<96) + Array(0..<96))
                    done.fulfill()
                }
            }
        }
        await fulfillment(of: [done], timeout: 5)
        queue.sync { pacer.cancel() }
    }

    func testFreshFramePrecedesOldKeyframeReplicaWithoutLosingCopies() async {
        let queue = DispatchQueue(label: "新画面优先于旧副本测试")
        let pacer = MacVideoDatagramPacer(queue: queue)
        let done = expectation(description: "首份及时交付且全部副本完整")
        queue.async {
            var output: [UInt8] = []
            let send: ([Data]) -> Void = { batch in
                output += batch.map { $0[0] }
                if output.count == 44 {
                    XCTAssertEqual(output, Array(0..<20) + Array(80..<84) + Array(0..<20))
                    done.fulfill()
                }
            }
            pacer.enqueue((0..<20).map { Data([UInt8($0)]) }, copies: 2, send: send)
            pacer.enqueue((80..<84).map { Data([UInt8($0)]) }, copies: 1, send: send)
        }
        await fulfillment(of: [done], timeout: 5)
        queue.sync { pacer.cancel() }
    }

    func testRepairPacketsPrecedeQueuedVideoWithoutReorderingItsRemainingPackets() async {
        let queue = DispatchQueue(label: "补发优先发送测试")
        let pacer = MacVideoDatagramPacer(queue: queue)
        let done = expectation(description: "补发优先且原帧完整")
        queue.async {
            var output: [UInt8] = []
            let send: ([Data]) -> Void = { batch in
                output += batch.map { $0[0] }
                if output.count == 21 {
                    XCTAssertEqual(output, Array(0..<8) + [99] + Array(8..<20))
                    done.fulfill()
                }
            }
            pacer.enqueue((0..<20).map { Data([UInt8($0)]) }, copies: 1, send: send)
            pacer.enqueue([Data([99])], copies: 1, priority: true, send: send)
        }
        await fulfillment(of: [done], timeout: 5)
        queue.sync { pacer.cancel() }
    }

    func testTimingReportsOnlyAfterEveryPacketAndReplicaIsSubmitted() async {
        let queue = DispatchQueue(label: "发送耗时诊断测试")
        let pacer = MacVideoDatagramPacer(queue: queue)
        let done = expectation(description: "整帧提交后报告一次耗时")
        done.assertForOverFulfill = true
        queue.async {
            var sent = 0
            pacer.enqueue(Array(repeating: Data([1]), count: 12), copies: 2,
                onTiming: { _, duration in
                    XCTAssertEqual(sent, 24)
                    XCTAssertGreaterThanOrEqual(duration, 1_800_000)
                    done.fulfill()
                }, send: { sent += $0.count })
        }
        await fulfillment(of: [done], timeout: 5)
        queue.sync { pacer.cancel() }
    }

    func testWirelessReceiverEnablesPacingEvenWithoutMacWiFi() {
        let streamer = MacScreenStreamer()
        streamer.captureQueue.sync {
            streamer.receiverUsesWiFi = true
            XCTAssertTrue(streamer.usesWirelessVideo)
            streamer.receiverUsesWiFi = false
            XCTAssertFalse(streamer.usesWirelessVideo)
        }
    }

    func testPacketsAndReplicasAreOrderedAcrossSmallSpacedBatches() async {
        let queue = DispatchQueue(label: "发送节奏测试")
        let pacer = MacVideoDatagramPacer(queue: queue)
        let done = expectation(description: "所有数据包按批发送")
        queue.async {
            var output: [UInt8] = []
            var times: [UInt64] = []
            let packets = (0..<20).map { Data([UInt8($0)]) }
            pacer.enqueue(packets, copies: 2) { batch in
                XCTAssertLessThanOrEqual(batch.count, 8)
                output += batch.map { $0[0] }
                times.append(DispatchTime.now().uptimeNanoseconds)
                if output.count == 40 {
                    XCTAssertEqual(output, Array(0..<20) + Array(0..<20))
                    for index in 1..<times.count {
                        XCTAssertGreaterThanOrEqual(times[index] - times[index - 1], 900_000)
                    }
                    done.fulfill()
                }
            }
        }
        await fulfillment(of: [done], timeout: 5)
        queue.sync { pacer.cancel() }
    }

    func testCancelPreventsOldPacketsFromEnteringNewStream() async {
        let queue = DispatchQueue(label: "发送取消测试")
        let pacer = MacVideoDatagramPacer(queue: queue)
        let done = expectation(description: "新流独立发送")
        queue.async {
            var oldPackets = 0
            pacer.enqueue(Array(repeating: Data([1]), count: 100), copies: 2) { batch in
                oldPackets += batch.count
                XCTAssertLessThanOrEqual(oldPackets, 8, "取消后旧流不得继续发送")
            }
            pacer.cancel()
            var newPackets = 0
            pacer.enqueue(Array(repeating: Data([2]), count: 20), copies: 1) { batch in
                XCTAssertTrue(batch.allSatisfy { $0 == Data([2]) })
                newPackets += batch.count
                if newPackets == 20 { done.fulfill() }
            }
        }
        await fulfillment(of: [done], timeout: 5)
        queue.sync { pacer.cancel() }
    }
}
