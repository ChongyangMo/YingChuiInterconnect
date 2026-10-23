import CoreGraphics
import Foundation
import Network
import XCTest
import YingchuiProtocol
@testable import YingchuiMac

final class DisplayModeTransportTests: XCTestCase, @unchecked Sendable {
    func testModesThroughControlProtocolAndRealEncoder() async throws {
        let host = MacHostModel(startServices: false)
        let physical = try YCVirtualDisplayBridge(pixelWidth: 1280, pixelHeight: 800, refreshRate: 60)
        host.selectedDisplayForStreaming.set(physical.displayID)
        let tcp = try NWListener(using: .tcp, on: .any)
        let udp = try NWListener(using: .udp, on: .any)
        let tcpReady = expectation(description: "控制通道就绪")
        let udpReady = expectation(description: "视频通道就绪")
        let packets = SynchronizedValue(0)
        let udpConnections = SynchronizedValue<[NWConnection]>([])
        tcp.stateUpdateHandler = { if case .ready = $0 { tcpReady.fulfill() } }
        udp.stateUpdateHandler = { if case .ready = $0 { udpReady.fulfill() } }
        tcp.newConnectionHandler = { connection in
            let session = HostPeerSession(connection: connection,
                onMessage: { session, message in host.handle(message, from: session) },
                onClosed: { _ in }, onStatus: { _ in })
            session.isAuthorized = true
            session.didReceiveHello = true
            session.deviceID = UUID().uuidString
            host.sessions[session.id] = session
            session.start(on: host.networkQueue)
        }
        udp.newConnectionHandler = { connection in
            udpConnections.mutate { $0.append(connection) }
            connection.start(queue: host.networkQueue)
            Self.receiveVideo(connection, count: packets)
        }
        tcp.start(queue: host.networkQueue)
        udp.start(queue: host.networkQueue)
        defer {
            host.networkQueue.sync {
                host.stopStreaming()
                host.sessions.values.forEach { $0.cancel() }
            }
            tcp.cancel(); udp.cancel()
            udpConnections.value.forEach { $0.cancel() }
            physical.invalidate()
        }
        await fulfillment(of: [tcpReady, udpReady], timeout: 5)
        let client = TestControlClient(port: try XCTUnwrap(tcp.port))
        defer { client.connection.cancel() }
        let videoPort = try XCTUnwrap(udp.port)
        var virtualID: CGDirectDisplayID?
        for mode in [RemoteDisplayMode.mirror, .extended, .mirror, .extended] {
            let request = WireMessage(kind: .streamStart, audioEnabled: false,
                videoPort: Int(videoPort.rawValue), width: 1280, height: 720,
                viewportWidth: 1280, viewportHeight: 720, frameRate: 60, bitRate: 4_000_000,
                displayMode: mode, displayPlacement: .right)
            let configured = expectation(description: "收到显示模式与视频配置")
            let response = SynchronizedValue<WireMessage?>(nil)
            client.send(try WireCodec.encode(request)) { message in
                guard let message, message.id == request.id else { return }
                let first = response.mutate { value in
                    guard value == nil else { return false }
                    value = message
                    return true
                }
                if first { configured.fulfill() }
            }
            await fulfillment(of: [configured], timeout: 12)
            let result = try XCTUnwrap(response.value)
            XCTAssertEqual(result.kind, .videoConfig, result.errorMessage ?? result.detail ?? "配置失败")
            XCTAssertEqual(result.displayState?.mode, mode)
            XCTAssertEqual(result.displayState?.placement, mode == .extended ? .right : nil)
            if let virtualID { XCTAssertEqual(host.virtualDisplayManager.activeDisplayID, virtualID) }
            else { virtualID = host.virtualDisplayManager.activeDisplayID }
            let before = packets.value
            for _ in 0..<40 {
                if packets.value > before { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertGreaterThan(packets.value, before, "每次切换后必须收到真实视频数据")
        }
        let readyForRemoval = expectation(description: "拔屏测试控制通道仍在线")
        let detached = expectation(description: "拔屏后确认实际显示拓扑")
        // 开发机可能仍有物理屏或另一个正在运行的回传虚拟屏。
        let remainingDisplays = try host.virtualDisplayManager.physicalDisplays().filter { $0 != physical.displayID }
        let expectedMode: RemoteDisplayMode = remainingDisplays.isEmpty ? .standalone : .extended
        let removed = SynchronizedValue(false)
        let didConfirm = SynchronizedValue(false)
        client.send(try WireCodec.encode(WireMessage(kind: .ping))) { message in
            guard let message else { return }
            if message.kind == .pong { readyForRemoval.fulfill() }
            if removed.value, message.displayState?.mode == expectedMode,
               didConfirm.mutate({ value in if value { return false }; value = true; return true }) {
                detached.fulfill()
            }
        }
        await fulfillment(of: [readyForRemoval], timeout: 5)
        let removedID = physical.displayID
        physical.invalidate()
        for _ in 0..<60 {
            if !(try MacDisplayRouting.onlineDisplays()).contains(removedID) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(try MacDisplayRouting.onlineDisplays().contains(removedID))
        removed.set(true)
        host.networkQueue.async { host.reconcileDisplayTopology() }
        await fulfillment(of: [detached], timeout: 12)
        XCTAssertEqual(host.virtualDisplayManager.activeDisplayID, virtualID)
        let before = packets.value
        for _ in 0..<40 {
            if packets.value > before { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(packets.value, before, "移除物理屏后仍持续回传")
    }

    private static func receiveVideo(_ connection: NWConnection, count: SynchronizedValue<Int>) {
        connection.receiveMessage { data, _, _, error in
            if let data, !data.isEmpty { count.mutate { $0 += 1 } }
            if error == nil { receiveVideo(connection, count: count) }
        }
    }
}
