import Network
import XCTest
import YingchuiProtocol
@testable import YingchuiMac

final class PeerDirectServiceTests: XCTestCase, @unchecked Sendable {
    func testDefaultRouteLossPreservesListenerAndActiveController() throws {
        let host = MacHostModel(startServices: false)
        host.wantsServiceRunning = true
        let listener = try NWListener(using: PeerNetworkTransport.discovery())
        let session = HostPeerSession(connection: NWConnection(host: .ipv4(.loopback), port: 9, using: .tcp),
                                      onMessage: { _, _ in }, onClosed: { _ in }, onStatus: { _ in })
        host.listener = listener
        host.sessions[session.id] = session
        host.controlSessionID = session.id
        defer { host.stopOnNetworkQueue(publish: false) }
        host.handleNetworkPathUpdate(.init(isAvailable: false, isWiFi: false))
        host.handleNetworkPathUpdate(.init(isAvailable: true, isWiFi: true))
        XCTAssertTrue(host.listener === listener)
        XCTAssertTrue(host.sessions[session.id] === session)
        XCTAssertEqual(host.controlSessionID, session.id)
        XCTAssertNil(host.listenerRetryWorkItem)
    }

    func testFailedListenerCanRetryWithoutDefaultNetworkAndStopCancelsRetry() throws {
        let host = MacHostModel(startServices: false)
        host.wantsServiceRunning = true
        try host.networkQueue.sync {
        host.lastNetworkState = .init(isAvailable: false, isWiFi: false)
        host.scheduleListenerRestart()
        let retry = try XCTUnwrap(host.listenerRetryWorkItem)
        XCTAssertEqual(host.listenerRetryAttempt, 1)
        host.scheduleListenerRestart()
        XCTAssertTrue(host.listenerRetryWorkItem === retry)
        host.wantsServiceRunning = false
        host.stopOnNetworkQueue(publish: false)
        XCTAssertTrue(retry.isCancelled)
        host.handleNetworkPathUpdate(.init(isAvailable: true, isWiFi: true))
        host.handleNetworkPathUpdate(.init(isAvailable: false, isWiFi: false))
        XCTAssertNil(host.listener)
        XCTAssertNil(host.listenerRetryWorkItem)
        }
    }

    func testSessionResolvesMediaAddressFromEstablishedConnection() async throws {
        let parameters = PeerNetworkTransport.discovery()
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let ready = expectation(description: "隔离控制服务已就绪")
        let received = expectation(description: "实际控制连接已收到消息")
        let queue = DispatchQueue(label: "PeerDirectServiceTests.transport")
        let sessions = SynchronizedValue<[HostPeerSession]>([])
        let mediaHost = SynchronizedValue<NWEndpoint.Host?>(nil)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            let session = HostPeerSession(connection: connection, onMessage: { session, _ in
                mediaHost.set(session.remoteHost)
                received.fulfill()
            }, onClosed: { _ in }, onStatus: { _ in })
            sessions.mutate { $0.append(session) }
            session.start(on: queue)
        }
        listener.start(queue: queue)
        defer { listener.cancel(); queue.sync { sessions.value.forEach { $0.cancel() } } }
        await fulfillment(of: [ready], timeout: 5)
        let client = NWConnection(host: .ipv4(.loopback), port: try XCTUnwrap(listener.port), using: PeerNetworkTransport.discovery())
        client.start(queue: queue)
        defer { client.cancel() }
        client.send(content: try WireCodec.encode(WireMessage(kind: .hello, deviceID: "测试设备")), completion: .contentProcessed { error in
            XCTAssertNil(error)
        })
        await fulfillment(of: [received], timeout: 5)
        XCTAssertEqual(mediaHost.value, .ipv4(.loopback))
    }

    func testOldListenerRetryCannotClearANewerRetry() throws {
        let host = MacHostModel(startServices: false)
        host.wantsServiceRunning = true
        try host.networkQueue.sync {
            host.scheduleListenerRestart()
            let old = try XCTUnwrap(host.listenerRetryWorkItem)
            // 模拟取消前已进入队列的旧回调；新一轮重试只能由自己的标识触发。
            host.listenerRetryWorkItem = nil
            host.scheduleListenerRestart()
            let current = try XCTUnwrap(host.listenerRetryWorkItem)
            old.perform()
            XCTAssertTrue(host.listenerRetryWorkItem === current)
            XCTAssertNil(host.listener)
            old.cancel()
            host.stopOnNetworkQueue(publish: false)
        }
    }
}
