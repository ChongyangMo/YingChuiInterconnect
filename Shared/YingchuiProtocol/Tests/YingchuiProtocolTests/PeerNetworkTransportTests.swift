import Network
import XCTest
@testable import YingchuiProtocol

final class PeerNetworkTransportTests: XCTestCase {
    func testLANFirstControlKeepsTLSAndTCPSettingsWhileExcludingPeerToPeer() throws {
        let options = NWProtocolTLS.Options()
        let parameters = PeerNetworkTransport.control(tls: options, includePeerToPeer: false)
        XCTAssertFalse(parameters.includePeerToPeer)
        XCTAssertNil(parameters.requiredInterface)
        XCTAssertEqual(parameters.serviceClass, .responsiveData)
        let tcp = try XCTUnwrap(parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)
        XCTAssertTrue(tcp.noDelay)
        XCTAssertTrue(parameters.defaultProtocolStack.applicationProtocols.contains { $0 is NWProtocolTLS.Options })
    }
    func testControlMessagesDoNotWaitForTCPPacketCoalescing() throws {
        let parameters = PeerNetworkTransport.control(tls: NWProtocolTLS.Options())
        let tcp = try XCTUnwrap(parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)
        XCTAssertTrue(tcp.noDelay)
        XCTAssertEqual(parameters.serviceClass, .responsiveData)
    }
    func testEveryTransportAllowsPeerDiscoveryWithoutForcingAWiFiInterface() {
        let parameters = [PeerNetworkTransport.discovery(),
                          PeerNetworkTransport.control(tls: NWProtocolTLS.Options()),
                          PeerNetworkTransport.video(), PeerNetworkTransport.audio()]
        for value in parameters {
            XCTAssertTrue(value.includePeerToPeer)
            XCTAssertNil(value.requiredInterface)
            XCTAssertEqual(value.requiredInterfaceType, .other)
        }
    }

    func testReconnectResolvesBonjourAgainButPreservesExplicitAddressScope() throws {
        let address = try XCTUnwrap(IPv6Address("fe80::1234%lo0"))
        let scope = try XCTUnwrap(address.interface)
        let service = NWEndpoint.service(name: "测试主机", type: "_yingchui._tcp",
                                         domain: "local.", interface: scope)
        XCTAssertEqual(PeerNetworkTransport.reconnectEndpoint(service),
                       .service(name: "测试主机", type: "_yingchui._tcp", domain: "local.", interface: nil))
        let explicit = NWEndpoint.hostPort(host: .ipv6(address), port: 50508)
        XCTAssertEqual(PeerNetworkTransport.reconnectEndpoint(explicit), explicit)
    }

    func testMediaKeepsResolvedIPv6ScopeAndUsesTheSameInterface() throws {
        let address = try XCTUnwrap(IPv6Address("fe80::1234%lo0"))
        let resolved = NWEndpoint.hostPort(host: .ipv6(address), port: 50508)
        let host = try XCTUnwrap(PeerNetworkTransport.mediaHost(remoteEndpoint: resolved))
        XCTAssertEqual(host, .ipv6(address))
        XCTAssertEqual(PeerNetworkTransport.video(host: host).requiredInterface, address.interface)
        XCTAssertEqual(PeerNetworkTransport.audio(host: host).requiredInterface, address.interface)
    }

    func testUnresolvedAndUnscopedLinkLocalMediaAddressesAreRejected() throws {
        let unscoped = try XCTUnwrap(IPv6Address("fe80::1234"))
        XCTAssertNil(PeerNetworkTransport.mediaHost(remoteEndpoint: .hostPort(host: .ipv6(unscoped), port: 9)))
        XCTAssertNil(PeerNetworkTransport.mediaHost(remoteEndpoint: .hostPort(host: .name("test.local", nil), port: 9)))
        XCTAssertNil(PeerNetworkTransport.mediaHost(remoteEndpoint: nil))
        XCTAssertEqual(PeerNetworkTransport.mediaHost(remoteEndpoint: .hostPort(host: .ipv4(.loopback), port: 9)), .ipv4(.loopback))
        XCTAssertEqual(PeerNetworkTransport.mediaHost(remoteEndpoint: .hostPort(host: .ipv6(.loopback), port: 9)), .ipv6(.loopback))
    }
}
