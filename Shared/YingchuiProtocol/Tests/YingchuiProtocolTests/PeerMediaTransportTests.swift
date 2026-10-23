import Network
import XCTest
@testable import YingchuiProtocol

final class PeerMediaTransportTests: XCTestCase, @unchecked Sendable {
    func testEncryptedVideoAndAudioTravelOverScopedIPv6UDP() async throws {
        for audio in [false, true] {
            let parameters = audio ? PeerNetworkTransport.audio() : PeerNetworkTransport.video()
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv6(.loopback), port: .any)
            let listener = try NWListener(using: parameters)
            let queue = DispatchQueue(label: "PeerMediaTransportTests.udp")
            let ready = expectation(description: "本地数据接收端已就绪")
            let received = expectation(description: "带作用域的加密数据已收到")
            let clients = SynchronizedValue<[NWConnection]>([])
            let key = VideoDatagramCrypto.makeKey()
            let payload = Data(repeating: audio ? 2 : 1, count: 900)
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready.fulfill() }
                if case .failed(let error) = state { XCTFail("接收端失败：\(error)"); ready.fulfill() }
            }
            listener.newConnectionHandler = { connection in
                clients.mutate { $0.append(connection) }
                connection.start(queue: queue)
                connection.receiveMessage { data, _, _, error in
                    XCTAssertNil(error)
                    do {
                        let decrypted = try VideoDatagramCrypto.open(XCTUnwrap(data), key: key)
                        XCTAssertEqual(decrypted, payload)
                    }
                    catch { XCTFail("数据解密失败：\(error)") }
                    received.fulfill()
                }
            }
            listener.start(queue: queue)
            defer { listener.cancel(); clients.value.forEach { $0.cancel() } }
            await fulfillment(of: [ready], timeout: 5)
            let address = try XCTUnwrap(IPv6Address("::1%lo0"))
            let host = NWEndpoint.Host.ipv6(address)
            let sender = NWConnection(host: host, port: try XCTUnwrap(listener.port),
                                      using: audio ? PeerNetworkTransport.audio(host: host) : PeerNetworkTransport.video(host: host))
            sender.start(queue: queue)
            defer { sender.cancel() }
            sender.send(content: try VideoDatagramCrypto.seal(payload, key: key), completion: .contentProcessed { error in
                XCTAssertNil(error)
            })
            await fulfillment(of: [received], timeout: 5)
        }
    }
}
