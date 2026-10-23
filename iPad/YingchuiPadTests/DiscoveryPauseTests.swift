import Network
import XCTest
import YingchuiProtocol
@testable import YingchuiPad

final class DiscoveryPauseTests: XCTestCase {
    @MainActor
    func testConnectionStopsDiscoveryAndNetworkUpdateCannotRestartIt() {
        let model = PadConnectionModel(startServices: false)
        model.networkQueue.sync {
            model.browser = NWBrowser(for: .bonjour(type: YingchuiService.bonjourType, domain: nil),
                using: PeerNetworkTransport.discovery())
            model.pauseBrowsingForConnection()
            XCTAssertNil(model.browser)
            XCTAssertTrue(model.discoveryPausedForConnection)
            XCTAssertTrue(model.resumeDiscoveryOnDisconnect)
            model.startBrowsingOnNetworkQueue()
            XCTAssertNil(model.browser)
            model.resumeBrowsingAfterDisconnect()
            XCTAssertNotNil(model.browser)
            XCTAssertFalse(model.discoveryPausedForConnection)
            model.stopBrowsingOnNetworkQueue()
        }
    }

    @MainActor
    func testBackgroundDisconnectDoesNotRestartDiscovery() {
        let model = PadConnectionModel(startServices: false)
        model.networkQueue.sync {
            model.browser = NWBrowser(for: .bonjour(type: YingchuiService.bonjourType, domain: nil),
                using: PeerNetworkTransport.discovery())
            model.pauseBrowsingForConnection()
            model.isInBackgroundState.set(true)
            model.resumeBrowsingAfterDisconnect()
            XCTAssertNil(model.browser)
            XCTAssertFalse(model.discoveryPausedForConnection)
            model.isInBackgroundState.set(false)
            model.startBrowsingOnNetworkQueue()
            XCTAssertNotNil(model.browser)
            model.stopBrowsingOnNetworkQueue()
        }
    }

    @MainActor
    func testIsolatedModelDoesNotStartServicesWhenDisconnected() {
        let model = PadConnectionModel(startServices: false)
        model.networkQueue.sync {
            model.pauseBrowsingForConnection()
            model.resumeBrowsingAfterDisconnect()
            XCTAssertNil(model.browser)
        }
    }
}
