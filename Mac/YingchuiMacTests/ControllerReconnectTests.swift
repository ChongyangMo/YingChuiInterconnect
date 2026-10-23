import Network
import XCTest
import YingchuiProtocol
@testable import YingchuiMac

final class ControllerReconnectTests: XCTestCase {
    private func session(_ host: MacHostModel, device: String, authorized: Bool) -> HostPeerSession {
        let peer = HostPeerSession(connection: NWConnection(host: .ipv4(.loopback), port: 9, using: .tcp),
                                   onMessage: { _, _ in }, onClosed: { _ in }, onStatus: { _ in })
        peer.deviceID = device
        peer.isAuthorized = authorized
        host.sessions[peer.id] = peer
        return peer
    }

    func testVerifiedReconnectRetiresOldOwnerAndLateOldMessagesCannotReclaim() {
        let host = MacHostModel(startServices: false)
        host.trustedDeviceTokens = ["pad": "verified-token"]
        let old = session(host, device: "pad", authorized: true)
        XCTAssertTrue(host.claimController(old))
        let next = session(host, device: "", authorized: false)
        host.handleHello(WireMessage(kind: .hello, deviceID: "pad", sessionToken: "verified-token"), from: next)
        XCTAssertTrue(next.isAuthorized)
        XCTAssertTrue(old.isSuperseded)
        XCTAssertFalse(old.isAuthorized)
        XCTAssertNil(host.sessions[old.id])
        XCTAssertTrue(host.claimController(next))
        host.handle(WireMessage(kind: .hello, deviceID: "pad", sessionToken: "verified-token"), from: old)
        XCTAssertFalse(host.claimController(old))
        host.remove(old)
        XCTAssertEqual(host.controlSessionID, next.id)
        next.cancel()
    }

    func testUnverifiedSameDeviceCannotEvictController() {
        let host = MacHostModel(startServices: false)
        host.trustedDeviceTokens = ["pad": "verified-token"]
        let old = session(host, device: "pad", authorized: true)
        XCTAssertTrue(host.claimController(old))
        let impostor = session(host, device: "", authorized: false)
        host.handleHello(WireMessage(kind: .hello, deviceID: "pad", sessionToken: "wrong-token"), from: impostor)
        XCTAssertFalse(impostor.isAuthorized)
        XCTAssertFalse(old.isSuperseded)
        XCTAssertEqual(host.controlSessionID, old.id)
        XCTAssertFalse(host.claimController(impostor))
        old.cancel(); impostor.cancel()
    }

    func testDifferentVerifiedDeviceStillCannotStealController() {
        let host = MacHostModel(startServices: false)
        host.trustedDeviceTokens = ["other-pad": "other-token"]
        let old = session(host, device: "pad", authorized: true)
        XCTAssertTrue(host.claimController(old))
        let other = session(host, device: "", authorized: false)
        host.handleHello(WireMessage(kind: .hello, deviceID: "other-pad", sessionToken: "other-token"), from: other)
        XCTAssertTrue(other.isAuthorized)
        XCTAssertFalse(old.isSuperseded)
        XCTAssertFalse(host.claimController(other))
        old.cancel(); other.cancel()
    }
}
