import Foundation
import Network
import XCTest
import YingchuiProtocol
@testable import YingchuiPad

final class WiFiVideoReceiverTests: XCTestCase, @unchecked Sendable {
    func testEncryptedFrameBurstsAndKeyFrameReplicasRemainComplete() async throws {
        try await verifyEncryptedFrameBursts(keyFrameBytes: 72_000)
    }

    func testPacedLargeDesktopKeyFramesRemainComplete() async throws {
        try await verifyEncryptedFrameBursts(keyFrameBytes: 260_000, paced: true)
    }

    private func verifyEncryptedFrameBursts(keyFrameBytes: Int, paced: Bool = false) async throws {
        let receiver = PadVideoReceiver()
        let ready = expectation(description: "突发接收端就绪")
        let first = expectation(description: "首帧已认证")
        let complete = expectation(description: "全部突发帧交付")
        let port = SynchronizedValue<UInt16?>(nil)
        let ids = SynchronizedValue<[UInt32]>([])
        let requests = SynchronizedValue(0)
        let stream = UUID(), key = VideoDatagramCrypto.makeKey()
        receiver.onReady = { value, _ in port.set(value); ready.fulfill() }
        receiver.onFrame = { frame, _ in
            ids.mutate { $0.append(frame.frameID) }
            if frame.frameID == 0 { first.fulfill() }
            if frame.frameID == 90 { complete.fulfill() }
        }
        receiver.onNeedsKeyFrame = { requests.mutate { $0 += 1 } }
        receiver.onRecoverableFailure = { XCTFail($0) }
        receiver.start()
        defer { receiver.stop() }
        await fulfillment(of: [ready], timeout: 5)
        receiver.expect(streamID: stream, videoKey: key)
        let sender = NWConnection(host: .ipv4(.loopback),
            port: try XCTUnwrap(NWEndpoint.Port(rawValue: XCTUnwrap(port.value))), using: .udp)
        sender.start(queue: DispatchQueue(label: "视频突发发送测试"))
        defer { sender.cancel() }
        func send(_ id: UInt32) async throws {
            let isKey = id.isMultiple(of: 30)
            let payload = Data(repeating: UInt8(id), count: isKey ? (id == 0 ? 72_000 : keyFrameBytes) : 18_000)
            let packets = try VideoDatagramCodec.fragment(accessUnit: payload, streamID: stream,
                frameID: id, presentationTimeMicroseconds: UInt64(id) * 16_667, isKeyFrame: isKey)
                .map { try VideoDatagramCrypto.seal($0, key: key) }
            let copies = isKey ? packets + packets : packets
            let batchSize = paced ? 8 : copies.count
            for offset in stride(from: 0, to: copies.count, by: batchSize) {
                sender.batch {
                    for packet in copies[offset..<min(offset + batchSize, copies.count)] {
                        sender.send(content: packet, completion: .contentProcessed { error in
                            if let error { XCTFail(error.localizedDescription) }
                        })
                    }
                }
                if paced { try await Task.sleep(for: .milliseconds(1)) }
            }
        }
        try await send(0)
        await fulfillment(of: [first], timeout: 5)
        for id in 1...UInt32(90) {
            try await send(id)
            try await Task.sleep(for: .milliseconds(17))
        }
        await fulfillment(of: [complete], timeout: 5)
        XCTAssertEqual(ids.value, Array(0...UInt32(90)))
        XCTAssertEqual(requests.value, 0, "密集分片与关键帧副本不应造成参考链中断")
    }

    func testEncryptedUDPReorderingPreservesReferenceChain() async throws {
        let receiver = PadVideoReceiver()
        let ready = expectation(description: "无线乱序测试接收端就绪")
        let first = expectation(description: "首帧已交付")
        let ordered = expectation(description: "乱序帧按顺序交付")
        let port = SynchronizedValue<UInt16?>(nil)
        let ids = SynchronizedValue<[UInt32]>([])
        let requests = SynchronizedValue(0)
        let stream = UUID(), key = VideoDatagramCrypto.makeKey()
        receiver.onReady = { value, _ in port.set(value); ready.fulfill() }
        receiver.onFrame = { frame, _ in
            ids.mutate { $0.append(frame.frameID) }
            if frame.frameID == 1 { first.fulfill() }
            if frame.frameID == 3 { ordered.fulfill() }
        }
        receiver.onNeedsKeyFrame = { requests.mutate { $0 += 1 } }
        receiver.onRecoverableFailure = { XCTFail($0) }
        receiver.start()
        defer { receiver.stop() }
        await fulfillment(of: [ready], timeout: 5)
        receiver.expect(streamID: stream, videoKey: key)
        let sender = NWConnection(host: .ipv4(.loopback),
            port: try XCTUnwrap(NWEndpoint.Port(rawValue: XCTUnwrap(port.value))), using: .udp)
        sender.start(queue: DispatchQueue(label: "无线乱序测试"))
        defer { sender.cancel() }
        func packets(_ id: UInt32, size: Int = 10) throws -> [Data] {
            try VideoDatagramCodec.fragment(accessUnit: Data(repeating: 1, count: size), streamID: stream,
                frameID: id, presentationTimeMicroseconds: UInt64(id) * 16_667, isKeyFrame: id == 1)
                .map { try VideoDatagramCrypto.seal($0, key: key) }
        }
        func send(_ packets: [Data]) async throws {
            for packet in packets {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    sender.send(content: packet, completion: .contentProcessed { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    })
                }
            }
        }
        try await send(packets(1))
        await fulfillment(of: [first], timeout: 5)
        let second = try packets(2, size: 2_000)
        try await send([XCTUnwrap(second.first)])
        try await send(packets(3))
        try await Task.sleep(for: .milliseconds(8))
        try await send(Array(second.dropFirst()))
        await fulfillment(of: [ordered], timeout: 5)
        XCTAssertEqual(ids.value, [1, 2, 3])
        XCTAssertEqual(requests.value, 0, "短暂乱序不应误报丢帧并请求关键帧")
    }
}
