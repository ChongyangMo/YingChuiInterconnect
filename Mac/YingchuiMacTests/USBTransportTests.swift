import Foundation
import Network
import XCTest
@testable import YingchuiMac
import YingchuiProtocol

final class USBTransportTests: XCTestCase {
    func testActualSystemUSBDeviceQueryCompletesWithoutInventingDevices() async throws {
        let devices = try await MacUSBMuxClient.devices(queue: DispatchQueue(label: "USB系统查询验证"))
        XCTAssertTrue(devices.allSatisfy { $0.id > 0 && !$0.serial.isEmpty })
        print("USB 系统查询验证：实际有线设备 \(devices.count) 台")
    }
    func testUnknownLoopbackAndLANPeersCannotClaimUSBMediaRoute() {
        XCTAssertTrue(MacUSBHostManager.isRelayLoopback("127.0.0.1"))
        XCTAssertTrue(MacUSBHostManager.isRelayLoopback("::ffff:127.0.0.1"))
        XCTAssertFalse(MacUSBHostManager.isRelayLoopback("192.168.50.2"))
        XCTAssertFalse(MacUSBHostManager.isRelayLoopback("127.0.0.2"))
        let manager = MacUSBHostManager(queue: DispatchQueue(label: "USB路由验证"),
            log: DiagnosticEventLog(subsystem: "com.yingchui.interconnect.mac", category: "USB验证"))
        XCTAssertNil(manager.mediaSink(remoteEndpoint: .hostPort(host: "127.0.0.1", port: 12345)))
        XCTAssertNil(manager.mediaSink(remoteEndpoint: .hostPort(host: "192.168.50.2", port: 12345)))
    }
}
