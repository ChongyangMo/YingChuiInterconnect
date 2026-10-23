import Foundation
import Network
import XCTest
import YingchuiProtocol
@testable import YingchuiMac

final class TestControlClient: @unchecked Sendable {
    let connection: NWConnection
    private let queue = DispatchQueue(label: "PairingConnectionTests.client")
    private var decoder = WireMessageDecoder()
    private var onResponse: (@Sendable (WireMessage?) -> Void)?

    init(port: NWEndpoint.Port) {
        connection = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state { self.receive() }
            if case .failed = state { self.onResponse?(nil) }
        }
        connection.start(queue: queue)
    }
    func send(_ data: Data, response: @escaping @Sendable (WireMessage?) -> Void) {
        queue.async {
            self.onResponse = response
            self.connection.send(content: data, completion: .contentProcessed { error in
                if error != nil { response(nil) }
            })
        }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            do {
                if let data {
                    for message in try self.decoder.append(data) { self.onResponse?(message) }
                }
            } catch { self.onResponse?(nil); return }
            if done || error != nil { return }
            self.receive()
        }
    }
}

final class PairingConnectionTests: XCTestCase, @unchecked Sendable {
    func testPairingReplyMatchesRequestAndBudgetSurvivesReconnect() async throws {
        let host = MacHostModel(startServices: false)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let ready = expectation(description: "隔离测试服务启动")
        let queue = DispatchQueue(label: "PairingConnectionTests.server")
        let sessions = SynchronizedValue<[HostPeerSession]>([])
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            let session = HostPeerSession(connection: connection,
                onMessage: { session, message in host.handle(message, from: session) },
                onClosed: { _ in }, onStatus: { _ in })
            sessions.mutate { $0.append(session) }
            session.start(on: queue)
        }
        listener.start(queue: queue)
        defer {
            listener.cancel()
            queue.sync { sessions.value.forEach { $0.cancel() } }
        }
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port)
        let first = TestControlClient(port: port)
        defer { first.connection.cancel() }
        let hello = WireMessage(kind: .hello, deviceID: "首次连接")
        let helloResponse = try await exchange(hello, with: first)
        XCTAssertEqual(helloResponse.id, hello.id)
        let stream = WireMessage(kind: .streamStart)
        let streamResponse = try await exchange(stream, with: first)
        XCTAssertEqual(streamResponse.id, stream.id)
        XCTAssertEqual(streamResponse.detail, "pairing_required")
        for _ in 0..<5 {
            let request = WireMessage(kind: .pairRequest, deviceID: "首次连接", pairingCode: "无效配对码")
            let response = try await exchange(request, with: first)
            XCTAssertEqual(response.id, request.id)
            XCTAssertEqual(response.detail, "invalid_pairing_code")
            XCTAssertEqual(response.accepted, false)
        }
        first.connection.cancel()
        let next = TestControlClient(port: port)
        defer { next.connection.cancel() }
        _ = try await exchange(WireMessage(kind: .hello, deviceID: "新的连接"), with: next)
        let request = WireMessage(kind: .pairRequest, deviceID: "新的连接", pairingCode: "无效配对码")
        let response = try await exchange(request, with: next)
        XCTAssertEqual(response.id, request.id)
        XCTAssertEqual(response.detail, "pairing_rate_limited")
        XCTAssertEqual(response.accepted, false)
    }

    private func exchange(_ message: WireMessage, with client: TestControlClient) async throws -> WireMessage {
        let received = expectation(description: "收到控制响应")
        let response = SynchronizedValue<WireMessage?>(nil)
        client.send(try WireCodec.encode(message)) { value in
            response.set(value)
            received.fulfill()
        }
        await fulfillment(of: [received], timeout: 5)
        return try XCTUnwrap(response.value)
    }
}
