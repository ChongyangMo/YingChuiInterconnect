import Network
import XCTest
import YingchuiProtocol
@testable import YingchuiPad

final class PeerDirectConnectionTests: XCTestCase, @unchecked Sendable {
    private let offline = LocalNetworkState(isAvailable: false, isWiFi: false)
    private let online = LocalNetworkState(isAvailable: true, isWiFi: true)
    private let service = NWEndpoint.service(name: "直连测试", type: "_yingchui._tcp", domain: "local.", interface: nil)

    @MainActor
    private func withModel(_ action: @escaping @Sendable (PadConnectionModel) throws -> Void) async throws {
        let model = PadConnectionModel(startServices: false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            model.networkQueue.async {
                defer {
                    model.reconnectWorkItem?.cancel()
                    model.reconnectWorkItem = nil
                    model.desiredEndpoint = nil
                    model.browser?.cancel()
                    model.browser = nil
                    model.disconnectOnNetworkQueue()
                }
                do { try action(model); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    @MainActor
    func testDefaultRouteLossPreservesActiveConnectionStreamIntentAndDiscovery() async throws {
        try await withModel { model in
            let connection = NWConnection(to: self.service, using: .tcp)
            let browser = NWBrowser(for: .bonjour(type: "_yingchui._tcp", domain: nil), using: PeerNetworkTransport.discovery())
            model.connection = connection
            model.browser = browser
            model.desiredEndpoint = self.service
            model.wantsStreaming = true
            let epoch = model.connectionEpoch.value
            model.handleNetworkPathUpdate(self.offline)
            model.handleNetworkPathUpdate(self.online)
            XCTAssertTrue(model.connection === connection)
            XCTAssertTrue(model.browser === browser)
            XCTAssertEqual(model.connectionEpoch.value, epoch)
            XCTAssertEqual(model.desiredEndpoint, self.service)
            XCTAssertTrue(model.wantsStreaming)
            XCTAssertNil(model.reconnectWorkItem)
        }
    }

    @MainActor
    func testNoDefaultNetworkStillStartsDiscoveryAndSchedulesReconnect() async throws {
        try await withModel { model in
            model.desiredEndpoint = self.service
            model.handleNetworkPathUpdate(self.offline)
            XCTAssertNotNil(model.browser)
            XCTAssertTrue(try XCTUnwrap(model.browser).parameters.includePeerToPeer)
            XCTAssertNotNil(model.reconnectWorkItem)
            XCTAssertEqual(model.reconnectAttempt, 1)
            model.scheduleReconnectIfNeeded()
            XCTAssertEqual(model.reconnectAttempt, 1)
        }
    }

    @MainActor
    func testBackgroundCannotStartDiscoveryOrReconnectEvenWhenRouteReturns() async throws {
        try await withModel { model in
            model.desiredEndpoint = self.service
            model.isInBackgroundState.set(true)
            model.handleNetworkPathUpdate(self.offline)
            model.handleNetworkPathUpdate(self.online)
            model.scheduleReconnectIfNeeded()
            model.connectOnNetworkQueue(to: self.service)
            XCTAssertNil(model.browser)
            XCTAssertNil(model.reconnectWorkItem)
            XCTAssertNil(model.connection)
            XCTAssertEqual(model.desiredEndpoint, self.service)
        }
    }

    @MainActor
    func testDiscoveryCannotReconnectAfterExplicitDisconnectOrSelectAnotherHost() async throws {
        try await withModel { model in
            let host = DiscoveredHost(endpoint: self.service, name: "测试主机", hostID: "selected")
            model.connectedHostKey = host.hostID
            model.refreshDesiredEndpoint(from: [host])
            model.handleNetworkPathUpdate(self.offline)
            XCTAssertNil(model.desiredEndpoint)
            XCTAssertNil(model.reconnectWorkItem)
            model.desiredEndpoint = self.service
            model.connectedHostKey = "different"
            let changed = DiscoveredHost(endpoint: .service(name: "新服务", type: "_yingchui._tcp", domain: "local.", interface: nil), name: "测试主机", hostID: "selected")
            model.refreshDesiredEndpoint(from: [changed])
            XCTAssertEqual(model.desiredEndpoint, self.service)
        }
    }

    @MainActor
    func testPendingReconnectUsesRefreshedServiceAndCannotCreateDuplicateConnection() async throws {
        try await withModel { model in
            model.connectedHostKey = UUID().uuidString
            model.desiredEndpoint = self.service
            model.scheduleReconnectIfNeeded()
            let retry = try XCTUnwrap(model.reconnectWorkItem)
            let updated = NWEndpoint.service(name: "重新发布的服务", type: "_yingchui._tcp", domain: "local.", interface: nil)
            model.refreshDesiredEndpoint(from: [DiscoveredHost(endpoint: updated, name: "测试主机", hostID: try XCTUnwrap(model.connectedHostKey))])
            retry.perform()
            let connection = try XCTUnwrap(model.connection)
            XCTAssertEqual(connection.endpoint, updated)
            model.connectOnNetworkQueue(to: self.service)
            XCTAssertTrue(model.connection === connection)
        }
    }

    @MainActor
    func testStaleReconnectCannotClearOrStartNewConnectionAttempt() async throws {
        try await withModel { model in
            model.desiredEndpoint = self.service
            model.scheduleReconnectIfNeeded()
            let old = try XCTUnwrap(model.reconnectWorkItem)
            model.connectionEpoch.set(UUID())
            let current = DispatchWorkItem {}
            model.reconnectWorkItem = current
            old.perform()
            XCTAssertTrue(model.reconnectWorkItem === current)
            XCTAssertNil(model.connection)
        }
    }

    @MainActor
    func testPeerSetupTimeoutRetriesButIdentityAndPairingTimeoutsStillStop() async throws {
        for phase in [PadConnectionPhase.connecting, .identifying, .pairing] {
            try await withModel { model in
                let connection = NWConnection(to: self.service, using: .tcp)
                model.connection = connection
                model.desiredEndpoint = self.service
                model.wantsStreaming = true
                model.armConnectionDeadline(phase, on: connection)
                model.expireConnectionDeadline(phase, on: connection, epoch: model.connectionEpoch.value)
                XCTAssertNil(model.connection)
                XCTAssertNil(model.connectionDeadlineWorkItem)
                if phase == .connecting {
                    XCTAssertEqual(model.desiredEndpoint, self.service)
                    XCTAssertTrue(model.wantsStreaming)
                    XCTAssertNotNil(model.reconnectWorkItem)
                } else {
                    XCTAssertNil(model.desiredEndpoint)
                    XCTAssertFalse(model.wantsStreaming)
                    XCTAssertNil(model.reconnectWorkItem)
                }
            }
        }
    }

    func testOnlyPeerServiceSetupGetsLongerDiscoveryDeadline() {
        XCTAssertEqual(PadConnectionPhase.connecting.timeoutSeconds(for: service), 30)
        XCTAssertEqual(PadConnectionPhase.connecting.timeoutSeconds(for: .hostPort(host: .ipv4(.loopback), port: 9)), 10)
        XCTAssertEqual(PadConnectionPhase.identifying.timeoutSeconds(for: service), 5)
        XCTAssertEqual(PadConnectionPhase.pairing.timeoutSeconds(for: service), 10)
    }
}
