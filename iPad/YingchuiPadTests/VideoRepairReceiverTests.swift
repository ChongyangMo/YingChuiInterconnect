import Foundation
import Network
import XCTest
import YingchuiProtocol
@testable import YingchuiPad

final class VideoRepairReceiverTests: XCTestCase, @unchecked Sendable {
    func testLostFragmentIsRepairedWithoutKeyFrameOrDiscardingFollowingFrame() async throws {
        try await exercise(repair: true)
    }

    func testUnsuccessfulRepairStillRequestsKeyFrame() async throws {
        try await exercise(repair: false)
    }

    private func exercise(repair: Bool) async throws {
        let receiver = PadVideoReceiver()
        defer { receiver.stop() }
        let ready = expectation(description: "补发接收端就绪")
        let first = expectation(description: "首帧完整")
        let requested = expectation(description: "请求唯一缺片")
        let done = expectation(description: repair ? "继续连续画面" : "补发超时进入关键帧恢复")
        let recovered = repair ? nil : expectation(description: "恢复关键帧完成")
        let statistics = repair ? nil : expectation(description: "恢复丢弃与网络缺帧分别统计")
        let port = SynchronizedValue<UInt16?>(nil)
        let ids = SynchronizedValue<[UInt32]>([])
        let stream = UUID(), key = VideoDatagramCrypto.makeKey()
        receiver.onReady = { value, _ in port.set(value); ready.fulfill() }
        receiver.onFrame = { frame, _ in
            ids.mutate { $0.append(frame.frameID) }
            if frame.frameID == 0 { first.fulfill() }
            if frame.frameID == 2 { done.fulfill() }
            if frame.frameID == 5 { recovered?.fulfill() }
        }
        receiver.onNeedsKeyFrame = {
            if repair { XCTFail("成功补片不能要求重建关键帧") }
            else { done.fulfill() }
        }
        receiver.onRecoverableFailure = { XCTFail($0) }
        let receivedStatistics = SynchronizedValue(false)
        receiver.onStatistics = { snapshot in
            guard !repair, ids.value.contains(5),
                  receivedStatistics.mutate({ value in if value { return false }; value = true; return true }) else { return }
            XCTAssertEqual(snapshot.networkMissing, 1, "等待恢复期间舍弃的帧不是新发生的网络丢失")
            XCTAssertEqual(snapshot.dropped, 4, "界面仍应显示全部未播放帧")
            statistics?.fulfill()
        }
        receiver.start()
        await fulfillment(of: [ready], timeout: 5)
        receiver.expect(streamID: stream, videoKey: key, supportsRepair: true)
        let sender = NWConnection(host: .ipv4(.loopback),
            port: try XCTUnwrap(NWEndpoint.Port(rawValue: XCTUnwrap(port.value))), using: .udp)
        let sendQueue = DispatchQueue(label: "缺片恢复发送测试")
        sender.start(queue: sendQueue)
        defer { sender.cancel() }
        func packets(_ id: UInt32, bytes: Int) throws -> [Data] {
            try VideoDatagramCodec.fragment(accessUnit: Data(repeating: UInt8(id), count: bytes),
                streamID: stream, frameID: id, presentationTimeMicroseconds: UInt64(id) * 16_667,
                isKeyFrame: id == 0 || id == 5).map { try VideoDatagramCrypto.seal($0, key: key) }
        }
        let missing = try packets(1, bytes: 3000)
        receiver.onNeedsVideoRepair = { actualStream, request in
            XCTAssertEqual(actualStream, stream)
            XCTAssertEqual(request, .init(frameID: 1, fragmentIndices: [1]))
            requested.fulfill()
            if repair {
                sendQueue.asyncAfter(deadline: .now() + .milliseconds(20)) {
                    sender.send(content: missing[1], completion: .contentProcessed { error in
                        if let error { XCTFail(error.localizedDescription) }
                    })
                }
            }
        }
        func send(_ data: Data) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                sender.send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
            }
        }
        try await send(packets(0, bytes: 10)[0])
        await fulfillment(of: [first], timeout: 5)
        try await send(missing[0]); try await send(missing[2])
        try await send(packets(2, bytes: 10)[0])
        await fulfillment(of: [requested, done], timeout: 3)
        XCTAssertEqual(ids.value, repair ? [0, 1, 2] : [0])
        if !repair {
            try await send(packets(5, bytes: 10)[0])
            await fulfillment(of: [try XCTUnwrap(recovered), try XCTUnwrap(statistics)], timeout: 3)
        }
    }
}
