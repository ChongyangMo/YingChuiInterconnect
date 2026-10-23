import Network
import XCTest
import YingchuiProtocol
@testable import YingchuiMac

@MainActor
final class MacAutomaticUpdateReservationTests: XCTestCase {
    func testNetworkReservationRejectsLateConnectionsAndWaitsForRealSessions() async {
        let host = MacHostModel(startServices: false)
        let existing = HostPeerSession(connection: NWConnection(host: .ipv4(.loopback), port: 9, using: .tcp),
            onMessage: { _, _ in }, onClosed: { _ in }, onStatus: { _ in })
        host.networkQueue.sync { host.sessions[existing.id] = existing }
        let whileConnected = await host.reserveAutomaticUpdate()
        XCTAssertFalse(whileConnected)
        XCTAssertFalse(host.automaticUpdateBarrier.value)
        host.networkQueue.sync {
            host.sessions.removeValue(forKey: existing.id)
            host.streamingSessionID = existing.id
        }
        let whilePreparing = await host.reserveAutomaticUpdate()
        XCTAssertFalse(whilePreparing)
        host.networkQueue.sync { host.streamingSessionID = nil }
        let idle = await host.reserveAutomaticUpdate()
        XCTAssertTrue(idle)
        XCTAssertTrue(host.automaticUpdateBarrier.value)
        let late = NWConnection(host: .ipv4(.loopback), port: 9, using: .tcp)
        host.networkQueue.sync {
            host.accept(late)
            XCTAssertTrue(host.sessions.isEmpty)
        }
        host.automaticUpdateBarrier.set(false)
        existing.cancel()
        late.cancel()
    }
}
