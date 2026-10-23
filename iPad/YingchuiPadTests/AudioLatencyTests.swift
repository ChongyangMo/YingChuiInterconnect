import Foundation
import XCTest
import YingchuiProtocol
@testable import YingchuiPad

final class AudioLatencyTests: XCTestCase, @unchecked Sendable {
    func testCatchUpHasHysteresisAndReturnsToNormalAtLowWatermark() {
        var controller = PadAudioLatencyController()
        XCTAssertNil(controller.update(bufferedMilliseconds: 100, now: 0))
        XCTAssertEqual(controller.update(bufferedMilliseconds: 170, now: 100_000_000), 1.02)
        XCTAssertNil(controller.update(bufferedMilliseconds: 130, now: 200_000_000))
        XCTAssertEqual(controller.rate, 1.02)
        XCTAssertEqual(controller.update(bufferedMilliseconds: 260, now: 300_000_000), 1.04)
        XCTAssertNil(controller.update(bufferedMilliseconds: 180, now: 400_000_000))
        XCTAssertEqual(controller.rate, 1.04)
        XCTAssertEqual(controller.update(bufferedMilliseconds: 80, now: 500_000_000), 1)
        XCTAssertNil(controller.update(bufferedMilliseconds: 300, now: 550_000_000))
        controller.reset()
        XCTAssertEqual(controller.rate, 1)
        XCTAssertEqual(controller.update(bufferedMilliseconds: 300, now: 550_000_000), 1.04)
    }

    func testBufferedAudioDrainsWhileRealtimePacketsContinueArriving() async throws {
        let player = PadAudioPlayer()
        let ready = expectation(description: "声音设备已就绪")
        let failures = SynchronizedValue<[String]>([])
        player.onFailure = { message in failures.mutate { $0.append(message) } }
        player.prepare { ready.fulfill() }
        defer { player.stop() }
        await fulfillment(of: [ready], timeout: 5)
        let stream = UUID()
        var sequence: UInt32 = 0
        func enqueueBatch(_ count: Int) {
            for _ in 0..<count {
                player.enqueue(AudioPacket(streamID: stream, sequence: sequence, pcm: Data(count: 960)))
                sequence += 1
            }
        }
        // 300 毫秒突发积压，后续仍严格按实时时钟提交，不能靠停发数据来消化。
        enqueueBatch(60)
        let clock = ContinuousClock()
        let start = clock.now
        for batch in 1...250 {
            try await clock.sleep(until: start.advanced(by: .milliseconds(batch * 20)))
            enqueueBatch(4)
        }
        XCTAssertTrue(failures.value.isEmpty, failures.value.joined(separator: "；"))
        XCTAssertLessThan(player.statistics.bufferedMilliseconds, 180)
        XCTAssertEqual(player.statistics.receivedFrames, UInt64(sequence) * 240)
        // 全部真实采样都必须渲染，调节不能清空或丢弃旧声音。
        for _ in 0..<100 {
            if player.statistics.bufferedFrames == 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(player.statistics.bufferedFrames, 0)
        XCTAssertEqual(player.statistics.renderedFrames, UInt64(sequence) * 240)
    }

    func testLargeBurstUsesBoundedCatchUpUntilLowWatermark() {
        var controller = PadAudioLatencyController()
        XCTAssertEqual(controller.update(bufferedMilliseconds: 867, now: 0), 1.12)
        XCTAssertNil(controller.update(bufferedMilliseconds: 450, now: 100_000_000))
        XCTAssertNil(controller.update(bufferedMilliseconds: 260, now: 200_000_000))
        XCTAssertEqual(controller.rate, 1.12)
        XCTAssertEqual(controller.update(bufferedMilliseconds: 80, now: 300_000_000), 1)
        XCTAssertEqual(controller.update(bufferedMilliseconds: 10_000, now: 400_000_000), 1.12)
    }
}
