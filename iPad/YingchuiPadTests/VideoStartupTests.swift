import Network
import XCTest
import YingchuiProtocol
@testable import YingchuiPad

final class VideoStartupTests: XCTestCase, @unchecked Sendable {
    func testStartupBufferHasSharedByteAndPacketLimits() throws {
        let a = UUID(), b = UUID()
        var buffer = PadVideoStartupBuffer(maximumBytes: 6, maximumPackets: 3)
        try buffer.append(Data([1, 2, 3, 4]), candidate: a)
        XCTAssertThrowsError(try buffer.append(Data([5, 6, 7]), candidate: b))
        try buffer.append(Data([5]), candidate: b)
        try buffer.append(Data([6]), candidate: b)
        XCTAssertThrowsError(try buffer.append(Data([7]), candidate: a))
        XCTAssertEqual(buffer.take(a), [Data([1, 2, 3, 4])])
        XCTAssertEqual(buffer.byteCount, 2)
        XCTAssertEqual(buffer.packetCount, 2)
        XCTAssertEqual(buffer.take(b), [Data([5]), Data([6])])
        XCTAssertEqual(buffer.byteCount, 0)
    }

    func testStartupBufferResetRemovesOldSessionAndRejectsOversizedPackets() throws {
        let id = UUID()
        var buffer = PadVideoStartupBuffer()
        XCTAssertThrowsError(try buffer.append(Data(count: 1_201), candidate: id))
        try buffer.append(Data([1]), candidate: id)
        buffer.reset()
        XCTAssertTrue(buffer.take(id).isEmpty)
        XCTAssertEqual(buffer.packetCount, 0)
        XCTAssertEqual(buffer.byteCount, 0)
    }

    func testEncryptedKeyFrameArrivingBeforeConfigurationIsPreserved() async throws {
        try await verifyBufferedStartup(reconfiguration: false)
    }

    func testReconfigurationPreservesEarlyKeyFrameWithoutTrustingOldSender() async throws {
        try await verifyBufferedStartup(reconfiguration: true)
    }

    func testLaterDeltaFrameCannotInvalidateIncompleteInitialKeyFrame() async throws {
        try await verifyBufferedStartup(reconfiguration: false, interleavedDelta: true)
    }

    private func verifyBufferedStartup(reconfiguration: Bool, interleavedDelta: Bool = false) async throws {
        let receiver = PadVideoReceiver()
        let ready = expectation(description: "视频端口就绪")
        let delivered = expectation(description: "先到的关键帧在配置到达后完成组装")
        let port = SynchronizedValue<UInt16?>(nil)
        let frames = SynchronizedValue<[CompletedVideoFrame]>([])
        let stream = UUID()
        let key = VideoDatagramCrypto.makeKey()
        let payload = Data(repeating: 0x42, count: 3_000)
        receiver.onReady = { value, _ in port.set(value); ready.fulfill() }
        let oldFrame = reconfiguration ? expectation(description: "旧流已认证并显示") : nil
        let oldStream = UUID()
        receiver.onFrame = { frame, _ in
            if frame.streamID == oldStream { oldFrame?.fulfill(); return }
            frames.mutate { $0.append(frame) }
            delivered.fulfill()
        }
        receiver.onRecoverableFailure = { XCTFail($0) }
        receiver.start()
        defer { receiver.stop() }
        await fulfillment(of: [ready], timeout: 5)
        var previousSender: NWConnection?
        defer { previousSender?.cancel() }
        if reconfiguration {
            let oldKey = VideoDatagramCrypto.makeKey()
            receiver.expect(streamID: oldStream, videoKey: oldKey)
            let previous = NWConnection(host: .ipv4(.loopback),
                port: try XCTUnwrap(NWEndpoint.Port(rawValue: XCTUnwrap(port.value))), using: .udp)
            previousSender = previous
            previous.start(queue: DispatchQueue(label: "旧视频流测试"))
            let oldPackets = try VideoDatagramCodec.fragment(accessUnit: Data([1]), streamID: oldStream,
                frameID: 0, presentationTimeMicroseconds: 1, isKeyFrame: true)
            for packet in oldPackets {
                previous.send(content: try VideoDatagramCrypto.seal(packet, key: oldKey),
                    completion: .contentProcessed { XCTAssertNil($0) })
            }
            await fulfillment(of: [try XCTUnwrap(oldFrame)], timeout: 5)
            await withCheckedContinuation { continuation in
                receiver.prepareForConfiguration { continuation.resume() }
            }
        }
        let sender = NWConnection(host: .ipv4(.loopback),
            port: try XCTUnwrap(NWEndpoint.Port(rawValue: XCTUnwrap(port.value))), using: .udp)
        sender.start(queue: DispatchQueue(label: "VideoStartupTests"))
        defer { sender.cancel() }
        let packets = try VideoDatagramCodec.fragment(accessUnit: payload, streamID: stream,
            frameID: 0, presentationTimeMicroseconds: 1_000_000, isKeyFrame: true)
        let sent = expectation(description: "关键帧分片全部发出")
        sent.expectedFulfillmentCount = packets.count
        for (index, packet) in packets.enumerated() {
            sender.send(content: try VideoDatagramCrypto.seal(packet, key: key),
                completion: .contentProcessed { error in XCTAssertNil(error); sent.fulfill() })
            if interleavedDelta, index == 0 {
                let deltas = try VideoDatagramCodec.fragment(accessUnit: Data([9]), streamID: stream,
                    frameID: 1, presentationTimeMicroseconds: 1_016_666, isKeyFrame: false)
                for delta in deltas {
                    sender.send(content: try VideoDatagramCrypto.seal(delta, key: key),
                        completion: .contentProcessed { XCTAssertNil($0) })
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        await fulfillment(of: [sent], timeout: 5)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(frames.value.isEmpty, "获得密钥之前不得交付未经认证的帧")
        receiver.expect(streamID: stream, videoKey: key)
        // 不再发包：验证配置到达本身就能释放已到达的完整关键帧。
        await fulfillment(of: [delivered], timeout: 3)
        XCTAssertEqual(frames.value.count, 1)
        XCTAssertEqual(frames.value.first?.accessUnit, payload)
        XCTAssertEqual(frames.value.first?.frameID, 0)
    }
}
