import Foundation
import Network
import XCTest
@testable import YingchuiProtocol

final class USBChannelNetworkTests: XCTestCase, @unchecked Sendable {
    func testRealLoopbackConnectionMultiplexesAndPreservesPayloads() async throws {
        let queue = DispatchQueue(label: "USB通道验证")
        let listener = try NWListener(using: .tcp)
        let channels = SynchronizedValue<[USBPacketChannel]>([])
        let received = SynchronizedValue<[UInt8: Data]>([:])
        let complete = expectation(description: "真实字节流往返完成")
        complete.expectedFulfillmentCount = 3
        let payload = try WireCodec.encode(WireMessage(kind: .ping))
        listener.newConnectionHandler = { raw in
            let channel = USBPacketChannel(connection: raw, queue: queue)
            channels.mutate { $0.append(channel) }
            channel.onPacket = { [weak channel] packet in channel?.send(packet.kind, payload: packet.payload) }
            channel.start()
        }
        listener.stateUpdateHandler = { state in
            guard case .ready = state, let port = listener.port else { return }
            let raw = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
            let channel = USBPacketChannel(connection: raw, queue: queue)
            channels.mutate { $0.append(channel) }
            channel.onPacket = { packet in
                received.mutate { $0[packet.kind.rawValue] = packet.payload }
                complete.fulfill()
            }
            channel.start()
            for kind in [USBPacketKind.control, .video, .audio] { channel.send(kind, payload: payload) }
        }
        listener.start(queue: queue)
        defer { listener.cancel(); channels.value.forEach { $0.close() } }
        await fulfillment(of: [complete], timeout: 5)
        XCTAssertEqual(received.value.count, 3)
        for value in received.value.values { XCTAssertEqual(value, payload) }
    }
}
