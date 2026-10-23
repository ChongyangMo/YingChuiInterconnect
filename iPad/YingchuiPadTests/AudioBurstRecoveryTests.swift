import Foundation
import XCTest
import YingchuiProtocol
@testable import YingchuiPad

final class AudioBurstRecoveryTests: XCTestCase, @unchecked Sendable {
    func test867MillisecondReceiveGapBurstKeepsEverySample() async throws {
        let player = PadAudioPlayer()
        let ready = expectation(description: "声音设备已准备")
        let failures = SynchronizedValue<[String]>([])
        player.onFailure = { message in failures.mutate { $0.append(message) } }
        player.prepare { ready.fulfill() }
        defer { player.stop() }
        await fulfillment(of: [ready], timeout: 5)
        let stream = UUID()
        player.enqueue(AudioPacket(streamID: stream, sequence: 0, pcm: Data(count: 960)))
        // 重现截图中的接收间隔；之后将这段时间的声音集中交给播放器。
        try await Task.sleep(for: .milliseconds(867))
        for sequence in 1...173 {
            player.enqueue(AudioPacket(streamID: stream, sequence: UInt32(sequence), pcm: Data(count: 960)))
        }
        player.enqueue(AudioPacket(streamID: stream, sequence: 174, pcm: Data(count: 384)))
        let expectedFrames: UInt64 = 240 + 41_616
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while (player.statistics.renderedFrames < expectedFrames || !player.diagnosticSummary.contains("声音突发积压已消化"))
                && failures.value.isEmpty && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(failures.value.isEmpty, failures.value.joined(separator: "；"))
        XCTAssertEqual(player.statistics.receivedFrames, expectedFrames)
        XCTAssertEqual(player.statistics.renderedFrames, expectedFrames)
        XCTAssertEqual(player.statistics.bufferedFrames, 0)
        XCTAssertTrue(player.diagnosticSummary.contains("声音突发积压已消化"), player.diagnosticSummary)
    }

    func testBurstCatchesUpWhileRealtimeAudioContinuesWithoutDiscardingSamples() async throws {
        let player = PadAudioPlayer()
        let ready = expectation(description: "实时声音播放设备就绪")
        let failures = SynchronizedValue<[String]>([])
        player.onFailure = { message in failures.mutate { $0.append(message) } }
        player.prepare { ready.fulfill() }
        defer { player.stop() }
        await fulfillment(of: [ready], timeout: 5)
        let stream = UUID()
        var sequence: UInt32 = 0
        func enqueue(_ count: Int) {
            for _ in 0..<count {
                player.enqueue(AudioPacket(streamID: stream, sequence: sequence, pcm: Data(count: 960)))
                sequence += 1
            }
        }
        enqueue(174)
        let clock = ContinuousClock(), start = ContinuousClock.now
        for batch in 1...400 {
            try await clock.sleep(until: start.advanced(by: .milliseconds(batch * 20)))
            enqueue(4)
        }
        XCTAssertTrue(failures.value.isEmpty, failures.value.joined(separator: "；"))
        XCTAssertLessThan(player.statistics.bufferedMilliseconds, 180)
        XCTAssertEqual(player.statistics.receivedFrames, UInt64(sequence) * 240)
        let deadline = clock.now.advanced(by: .seconds(2))
        while player.statistics.bufferedFrames > 0 && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(player.statistics.renderedFrames, UInt64(sequence) * 240)
        XCTAssertEqual(player.statistics.bufferedFrames, 0)
    }

    func testBurstReservationKeepsOldTicketsAndHardLimitStillStopsGrowth() throws {
        let budget = PadAudioBufferBudget(), generation = budget.generation
        let tickets = try (0..<174).map { _ in try budget.reserve(frames: 240, generation: generation) }
        XCTAssertEqual(budget.generation, generation)
        XCTAssertEqual(budget.statistics.bufferedMilliseconds, 870)
        XCTAssertTrue(budget.rendered(tickets[0]))
        XCTAssertEqual(budget.statistics.bufferedMilliseconds, 865)
        for _ in 0..<227 { _ = try budget.reserve(frames: 240, generation: generation) }
        XCTAssertEqual(budget.statistics.bufferedMilliseconds, 2_000)
        XCTAssertThrowsError(try budget.reserve(frames: 240, generation: generation)) { error in
            XCTAssertTrue(error.localizedDescription.contains("2000"))
        }
        XCTAssertEqual(budget.statistics.bufferedMilliseconds, 2_000)
    }
}
