import Network
import XCTest
import YingchuiProtocol
@testable import YingchuiPad

final class ConnectionRouteTests: XCTestCase, @unchecked Sendable {
    private let endpoint = NWEndpoint.service(name: "路由验证", type: "_yingchui._tcp", domain: "local.", interface: nil)

    @MainActor
    func testUnreadyLANConnectionRetriesPeerToPeerOnlyOnce() async {
        let model = PadConnectionModel(startServices: false)
        let endpoint = endpoint
        await withCheckedContinuation { continuation in
            model.networkQueue.async {
                let previous = NWConnection(to: endpoint, using: .tcp)
                model.connection = previous
                model.desiredEndpoint = endpoint
                model.connectionPhase = .connecting
                let epoch = model.connectionEpoch.value
                XCTAssertTrue(model.retryWithPeerToPeer(on: previous, endpoint: endpoint, epoch: epoch))
                XCTAssertFalse(model.connection === previous)
                XCTAssertTrue(model.connectionAllowsPeerToPeer)
                XCTAssertNil(model.connectionRouteFallbackWorkItem)
                XCTAssertFalse(model.retryWithPeerToPeer(on: previous, endpoint: endpoint, epoch: epoch))
                model.disconnectOnNetworkQueue()
                continuation.resume()
            }
        }
    }

    @MainActor
    func testFallbackCannotBypassIdentityFailureOrRestartEstablishedHandshake() async {
        let model = PadConnectionModel(startServices: false)
        let endpoint = endpoint
        await withCheckedContinuation { continuation in
            model.networkQueue.async {
                let current = NWConnection(to: endpoint, using: .tcp)
                model.connection = current
                model.desiredEndpoint = endpoint
                model.connectionPhase = .connecting
                let epoch = model.connectionEpoch.value
                model.pendingConnectionFailureReason = "证书与已配对设备不一致"
                XCTAssertFalse(model.retryWithPeerToPeer(on: current, endpoint: endpoint, epoch: epoch))
                model.pendingConnectionFailureReason = nil
                model.connectionPhase = .identifying
                XCTAssertFalse(model.retryWithPeerToPeer(on: current, endpoint: endpoint, epoch: epoch))
                model.connectionPhase = .connecting
                model.isInBackgroundState.set(true)
                XCTAssertFalse(model.retryWithPeerToPeer(on: current, endpoint: endpoint, epoch: epoch))
                model.isInBackgroundState.set(false)
                XCTAssertFalse(model.retryWithPeerToPeer(on: current, endpoint: endpoint, epoch: UUID()))
                XCTAssertTrue(model.connection === current)
                model.disconnectOnNetworkQueue()
                continuation.resume()
            }
        }
    }
}
