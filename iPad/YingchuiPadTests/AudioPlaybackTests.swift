import AVFoundation
import Foundation
import XCTest
import YingchuiProtocol
@testable import YingchuiPad

final class AudioPlaybackTests: XCTestCase, @unchecked Sendable {
    func testStoppedEngineRestartsBeforeAcceptingMoreAudio() async throws {
        let engine = AVAudioEngine()
        let player = PadAudioPlayer(engine: engine)
        let ready = expectation(description: "声音设备已准备")
        let rendered = expectation(description: "引擎停止后声音恢复渲染")
        let failures = SynchronizedValue<[String]>([])
        player.onFailure = { message in failures.mutate { $0.append(message) } }
        player.onRendered = { rendered.fulfill() }
        player.prepare { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertTrue(engine.isRunning)
        engine.stop()
        XCTAssertFalse(engine.isRunning)
        player.enqueue(AudioPacket(streamID: UUID(), sequence: 0, pcm: Data(count: 960)))
        await fulfillment(of: [rendered], timeout: 5)
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(player.statistics.bufferedFrames, 0)
        XCTAssertEqual(player.statistics.renderedFrames, 240)
        XCTAssertTrue(failures.value.isEmpty, failures.value.joined(separator: "；"))
        player.stop()
    }

    func testPreparedPlaybackKeepsRenderingDuringMainThreadStall() async throws {
        let player = PadAudioPlayer()
        let ready = expectation(description: "接收声音之前完成设备初始化")
        let rendered = expectation(description: "主线程繁忙期间声音持续渲染")
        rendered.expectedFulfillmentCount = 240
        let uiFinished = expectation(description: "主线程恢复")
        let failures = SynchronizedValue<[String]>([])
        player.onFailure = { message in failures.mutate { $0.append(message) } }
        player.onRendered = { rendered.fulfill() }
        player.prepare { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 5)
        // 与收到新视频配置时一致：换流不能重新关闭已准备好的声音设备。
        player.resetStream()
        DispatchQueue.main.async {
            Thread.sleep(forTimeInterval: 0.8)
            uiFinished.fulfill()
        }
        let stream = UUID()
        for batch in 0..<60 {
            for fragment in 0..<4 {
                player.enqueue(AudioPacket(streamID: stream, sequence: UInt32(batch * 4 + fragment), pcm: Data(count: 960)))
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        await fulfillment(of: [rendered, uiFinished], timeout: 5)
        XCTAssertTrue(failures.value.isEmpty, failures.value.joined(separator: "；"))
        XCTAssertEqual(player.statistics.renderedFrames, 57_600)
        XCTAssertEqual(player.statistics.bufferedFrames, 0)
        player.stop()
    }

    func testColdStartAcceptsAudioBurstWithoutQueueFailure() async {
        let player = PadAudioPlayer()
        let rendered = expectation(description: "启动时的声音完整进入播放引擎")
        rendered.expectedFulfillmentCount = 40
        let failures = SynchronizedValue<[String]>([])
        player.onFailure = { message in failures.mutate { $0.append(message) } }
        player.onRendered = { rendered.fulfill() }
        let stream = UUID()
        for sequence in 0..<40 {
            player.enqueue(AudioPacket(streamID: stream, sequence: UInt32(sequence), pcm: Data(count: 960)))
        }
        await fulfillment(of: [rendered], timeout: 5)
        player.stop()
        XCTAssertTrue(failures.value.isEmpty, failures.value.joined(separator: "；"))
    }

    func testSmallFragmentsAreCountedByAudioDuration() async {
        let player = PadAudioPlayer()
        let rendered = expectation(description: "短分片声音完整渲染")
        rendered.expectedFulfillmentCount = 100
        player.onFailure = { XCTFail($0) }
        player.onRendered = { rendered.fulfill() }
        let stream = UUID()
        for sequence in 0..<100 {
            player.enqueue(AudioPacket(streamID: stream, sequence: UInt32(sequence), pcm: Data(count: 192)))
        }
        await fulfillment(of: [rendered], timeout: 5)
        XCTAssertEqual(player.statistics.renderedFrames, 4_800)
        XCTAssertEqual(player.statistics.bufferedFrames, 0)
        player.stop()
    }

    func testContinuousPlaybackReturnsCapacityWhilePacketsKeepArriving() async throws {
        let player = PadAudioPlayer()
        let rendered = expectation(description: "连续声音没有累积满队列")
        rendered.expectedFulfillmentCount = 240
        player.onFailure = { XCTFail($0) }
        player.onRendered = { rendered.fulfill() }
        let stream = UUID()
        for batch in 0..<60 {
            for fragment in 0..<4 {
                player.enqueue(AudioPacket(streamID: stream, sequence: UInt32(batch * 4 + fragment), pcm: Data(count: 960)))
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        await fulfillment(of: [rendered], timeout: 5)
        XCTAssertEqual(player.statistics.renderedFrames, 57_600)
        XCTAssertEqual(player.statistics.bufferedFrames, 0)
        player.stop()
    }

    func testBudgetRejectsTrueOverflowAndReleasesRenderedCapacityImmediately() throws {
        let budget = PadAudioBufferBudget(), generation = budget.generation
        let tickets = try (0..<400).map { _ in try budget.reserve(frames: 240, generation: generation) }
        XCTAssertEqual(budget.statistics.bufferedMilliseconds, 2_000)
        XCTAssertThrowsError(try budget.reserve(frames: 240, generation: generation))
        XCTAssertTrue(budget.rendered(tickets[0]))
        XCTAssertNoThrow(try budget.reserve(frames: 240, generation: generation))
    }

    func testOldRenderCallbackCannotReleaseCapacityOfNewPlayback() throws {
        let budget = PadAudioBufferBudget()
        let old = try budget.reserve(frames: 240, generation: budget.generation)
        budget.reset()
        _ = try budget.reserve(frames: 48, generation: budget.generation)
        XCTAssertFalse(budget.rendered(old))
        XCTAssertEqual(budget.statistics.bufferedFrames, 48)
    }

    func testTinyPacketFloodIsBoundedBeforeSchedulingMoreWork() throws {
        let budget = PadAudioBufferBudget(), generation = budget.generation
        for _ in 0..<512 { _ = try budget.reserve(frames: 1, generation: generation) }
        XCTAssertThrowsError(try budget.reserve(frames: 1, generation: generation)) { error in
            XCTAssertTrue(error.localizedDescription.contains("512"))
        }
        XCTAssertEqual(budget.statistics.bufferedPackets, 512)
    }

    func testFatalAudioFailureCannotRestartFromAlreadyQueuedPackets() throws {
        let budget = PadAudioBufferBudget(), generation = budget.generation
        let old = try budget.reserve(frames: 240, generation: generation)
        XCTAssertTrue(budget.fail(generation))
        XCTAssertFalse(budget.fail(generation))
        XCTAssertThrowsError(try budget.reserve(frames: 240, generation: generation))
        XCTAssertFalse(budget.rendered(old))
        budget.reset()
        XCTAssertNoThrow(try budget.reserve(frames: 240, generation: budget.generation))
    }
}
