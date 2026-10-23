import AVFoundation
import Network
import XCTest
import YingchuiProtocol
@testable import YingchuiMac

final class AudioSenderTests: XCTestCase, @unchecked Sendable {
    func testPCMConversionInterleavesAndClampsWithoutLosingSamples() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
            channels: 2, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        buffer.frameLength = 2
        let channels = try XCTUnwrap(buffer.floatChannelData)
        channels[0][0] = 2; channels[1][0] = -2
        channels[0][1] = 0; channels[1][1] = 0.5
        XCTAssertEqual(try MacAudioSender.interleavedPCM(buffer), Data([255, 127, 1, 128, 0, 0, 0, 64]))
        channels[0][0] = .nan
        XCTAssertThrowsError(try MacAudioSender.interleavedPCM(buffer))
    }

    func testBudgetRejectsTrueBacklogAndReleasesCompletedFrames() throws {
        let budget = MacAudioSendBudget()
        let generation = try budget.reserve(frames: MacAudioSendBudget.maximumFrames)
        XCTAssertThrowsError(try budget.reserve(frames: 1))
        XCTAssertTrue(budget.complete(frames: 240, generation: generation))
        XCTAssertNoThrow(try budget.reserve(frames: 240))
    }

    func testOldCompletionAndFailureCannotAffectRestartedSender() throws {
        let budget = MacAudioSendBudget()
        let old = try budget.reserve(frames: 240)
        XCTAssertTrue(budget.fail(old))
        XCTAssertFalse(budget.fail(old))
        XCTAssertThrowsError(try budget.reserve(frames: 240))
        budget.reset()
        _ = try budget.reserve(frames: MacAudioSendBudget.maximumFrames)
        XCTAssertFalse(budget.complete(frames: 240, generation: old))
        XCTAssertFalse(budget.fail(old))
        XCTAssertThrowsError(try budget.reserve(frames: 1))
    }

    func testNetworkBurstLongerThanOldLimitRemainsBoundedAndCompletes() throws {
        let budget = MacAudioSendBudget()
        let generation = try budget.reserve(frames: 41_616)
        XCTAssertEqual(budget.pendingFrames, 41_616)
        XCTAssertTrue(budget.complete(frames: 41_616, generation: generation))
        XCTAssertEqual(budget.pendingFrames, 0)
        XCTAssertThrowsError(try budget.reserve(frames: MacAudioSendBudget.maximumFrames + 1))
        XCTAssertEqual(budget.pendingFrames, 0)
    }

    func testCaptureStartupBurstReachesUDPReceiverInFull() async throws {
        let ready = expectation(description: "声音测试接收端就绪")
        let received = expectation(description: "完整收到二百毫秒声音突发")
        received.expectedFulfillmentCount = 40
        let listener = try NWListener(using: .udp, on: .any)
        let queue = DispatchQueue(label: "声音发送测试")
        let stream = UUID(), key = VideoDatagramCrypto.makeKey()
        let port = SynchronizedValue<NWEndpoint.Port?>(nil)
        let frames = SynchronizedValue(0)
        let peer = SynchronizedValue<NWConnection?>(nil)
        listener.stateUpdateHandler = { state in
            if case .ready = state { port.set(listener.port); ready.fulfill() }
            if case .failed(let error) = state { XCTFail(error.localizedDescription) }
        }
        @Sendable func receive(_ connection: NWConnection) {
            connection.receiveMessage { data, _, _, error in
                XCTAssertNil(error)
                guard let data else { return }
                do {
                    let packet = try AudioPacketCodec.decode(VideoDatagramCrypto.open(data, key: key))
                    XCTAssertEqual(packet.streamID, stream)
                    frames.mutate { $0 += packet.frameCount }
                    received.fulfill()
                    if frames.value < 9_600 { receive(connection) }
                } catch { XCTFail(error.localizedDescription) }
            }
        }
        listener.newConnectionHandler = { connection in
            peer.set(connection)
            connection.start(queue: queue)
            receive(connection)
        }
        listener.start(queue: queue)
        defer { peer.value?.cancel(); listener.cancel() }
        await fulfillment(of: [ready], timeout: 5)
        let destination = try XCTUnwrap(port.value)
        let sender = MacAudioSender()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                sender.start(host: .ipv4(.loopback), port: destination, streamID: stream, key: key,
                             queue: queue, onFailure: { XCTFail($0) })
                do {
                    try sender.send(Self.sample(frames: 9_600, fill: 0))
                    continuation.resume()
                }
                catch { continuation.resume(throwing: error) }
            }
        }
        await fulfillment(of: [received], timeout: 5)
        XCTAssertEqual(frames.value, 9_600)
        await withCheckedContinuation { continuation in queue.async { sender.stop(); continuation.resume() } }
    }

    private static func sample(frames: Int, fill: CChar) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000,
                                               channels: 2, interleaved: true))
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: frames * 4, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: frames * 4, flags: 0, blockBufferOut: &block), noErr)
        let data = try XCTUnwrap(block)
        XCTAssertEqual(CMBlockBufferFillDataBytes(with: fill, blockBuffer: data,
                                                offsetIntoDestination: 0, dataLength: frames * 4), noErr)
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                       presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var size = 4
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: data,
            formatDescription: format.formatDescription, sampleCount: frames, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
}
