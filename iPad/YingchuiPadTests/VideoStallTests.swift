import Foundation
import Network
import XCTest
@testable import YingchuiPad

final class VideoStallTests: XCTestCase, @unchecked Sendable {
    func testSparseRealFramesKeepStreamHealthy() {
        var policy = PadVideoStallPolicy()
        for second in 0..<20 {
            let now = UInt64(second) * 1_000_000_000
            policy.recordProgress(now: now)
            XCTAssertEqual(policy.evaluate(now: now + 999_000_000), .none)
        }
    }

    func testQueuedCallbacksCannotAccumulateFakeStallTime() {
        var policy = PadVideoStallPolicy()
        policy.recordProgress(now: 0)
        for _ in 0..<10 {
            XCTAssertEqual(policy.evaluate(now: 1_000_000_000), .none)
        }
        XCTAssertEqual(policy.evaluate(now: 2_000_000_000), .requestKeyFrame)
        XCTAssertEqual(policy.evaluate(now: 2_000_000_001), .none)
        XCTAssertEqual(policy.evaluate(now: 3_000_000_000), .requestKeyFrame)
        XCTAssertEqual(policy.evaluate(now: 4_000_000_000), .recover)
    }

    func testActualDecodeResetsProbeAndRecoveryDeadline() {
        var policy = PadVideoStallPolicy()
        policy.recordProgress(now: 0)
        XCTAssertEqual(policy.evaluate(now: 3_000_000_000), .requestKeyFrame)
        policy.recordProgress(now: 3_100_000_000)
        XCTAssertEqual(policy.evaluate(now: 4_000_000_000), .none)
        XCTAssertEqual(policy.evaluate(now: 7_100_000_000), .recover)
    }

    @MainActor
    func testStatisticsRejectOldReceiverOldStreamNegotiationAndStaleDelivery() {
        let model = PadConnectionModel(startServices: false)
        model.wantsStreaming = true
        model.isStreaming = true
        let generation = UUID(), streamID = UUID()
        model.videoReceiverGeneration.set(generation)
        model.activeStreamID = streamID
        let now: UInt64 = 10_000_000_000
        func sample(generation id: UUID? = nil, stream: UUID? = nil,
                    time: UInt64? = nil) -> PadVideoReceiveSnapshot {
            PadVideoReceiveSnapshot(generation: id ?? generation, streamID: stream ?? streamID, uptimeNanoseconds: time ?? now,
                packets: 10, assembled: 5, dropped: 1)
        }
        model.handleVideoStatistics(sample(generation: UUID()), now: now)
        model.handleVideoStatistics(sample(stream: UUID()), now: now)
        model.handleVideoStatistics(sample(time: 1), now: now)
        XCTAssertNil(model.previousStatistics)
        model.videoConfigurationPending = true
        model.handleVideoStatistics(sample(), now: now)
        XCTAssertNil(model.previousStatistics)
        model.videoConfigurationPending = false
        model.playbackStatistics.recordDecodedFrame()
        model.videoStallPolicy.recordProgress(now: now)
        model.handleVideoStatistics(sample(), now: now)
        XCTAssertEqual(model.videoFramesDecoded, 1)
        XCTAssertEqual(model.videoPacketsReceived, 10)
        XCTAssertEqual(model.previousStatistics?.assembled, 5)
        model.playbackStatistics.recordDecodedFrame()
        model.handleVideoStatistics(sample(time: now - 1), now: now)
        XCTAssertEqual(model.videoFramesDecoded, 1, "倒序统计不能覆盖已接受的快照")
        model.handleVideoStatistics(sample(time: now + 1), now: now + 1)
        XCTAssertEqual(model.videoFramesDecoded, 2, "读取实际处理时的最新解码数")
        model.stopStreaming()
    }

    @MainActor
    func testPersistentStallRestartsOnlyMediaAndDecodeProgressCancelsQueuedRecovery() async {
        for decodedBeforeRecovery in [false, true] {
            let model = PadConnectionModel(startServices: false)
            let connection = NWConnection(host: .ipv4(.loopback), port: 9, using: .tcp)
            let generation = UUID(), streamID = UUID()
            model.connection = connection
            model.wantsStreaming = true
            model.isStreaming = true
            model.videoReceiverGeneration.set(generation)
            model.activeStreamID = streamID
            model.videoStallPolicy.recordProgress(now: 0)
            model.networkQueue.suspend()
            model.handleVideoStatistics(PadVideoReceiveSnapshot(
                generation: generation, streamID: streamID, uptimeNanoseconds: 4_000_000_000,
                packets: 10, assembled: 5, dropped: 0), now: 4_000_000_000)
            if decodedBeforeRecovery { model.playbackStatistics.recordDecodedFrame() }
            model.networkQueue.resume()
            await withCheckedContinuation { continuation in
                model.networkQueue.async {
                    XCTAssertTrue(model.connection === connection, "视频停滞不能重建控制连接")
                    XCTAssertEqual(model.activeStreamID, decodedBeforeRecovery ? streamID : nil)
                    XCTAssertEqual(model.streamRecoveryWorkItem != nil, !decodedBeforeRecovery)
                    continuation.resume()
                }
            }
            model.stopStreaming()
            model.networkQueue.async { model.disconnectOnNetworkQueue() }
        }
    }
}
