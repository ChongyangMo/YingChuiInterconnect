import AVFoundation
import Combine
import Network
import XCTest
import YingchuiProtocol
@testable import YingchuiPad

final class FeatureUpgradeTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testQuickConnectReportsMissingLastHostWithoutStartingNetwork() {
        let model = PadConnectionModel(startServices: false)
        model.lastHostID = UUID().uuidString
        model.discoveredHosts = []
        model.quickConnect()
        XCTAssertNil(model.connection)
        XCTAssertTrue(model.discoveryStatus.contains("不在线"))
    }

    @MainActor
    func testLiveQualityChangeKeepsStreamingIntent() {
        let model = PadConnectionModel(startServices: false)
        model.wantsStreaming = true
        model.isStreaming = true
        model.selectQuality(.balanced)
        XCTAssertEqual(model.streamRequest, StreamRequest(quality: .balanced, viewport: model.viewport, maximumFrameRate: model.maximumDisplayFrameRate))
        XCTAssertEqual(model.activeQuality, .balanced)
        XCTAssertTrue(model.wantsStreaming)
        XCTAssertTrue(model.isStreaming)
        model.stopStreaming()
    }

    @MainActor
    func testInvalidKeyboardInputIsReportedBeforeSending() {
        let model = PadConnectionModel(startServices: false)
        model.isPaired = true
        XCTAssertFalse(model.submitText(String(repeating: "鹰", count: 4_097)))
        XCTAssertTrue(model.transferStatus.contains("超过"))
        XCTAssertTrue(model.pendingTextIDs.isEmpty)
    }

    @MainActor
    func testUnsolicitedClipboardCannotWritePasteboard() async {
        let model = PadConnectionModel(startServices: false)
        model.handleClipboardResult(WireMessage(kind: .clipboardResult, accepted: true, text: "未经请求"))
        await Task.yield()
        XCTAssertTrue(model.transferStatus.isEmpty)
        XCTAssertNil(model.pendingClipboardRequest)
    }

    @MainActor
    func testQuickConnectionEntersFullScreenOnlyOnFirstDecodedFrame() {
        let model = PadConnectionModel(startServices: false)
        model.enterFullScreenAfterConnection = true
        model.wantsStreaming = true
        XCTAssertFalse(model.shouldPresentFullScreen)
        model.videoRenderer.onFrameDecoded?(1)
        XCTAssertTrue(model.videoIsPlaying)
        XCTAssertTrue(model.shouldPresentFullScreen)
        model.shouldPresentFullScreen = false
        model.videoRenderer.onFrameDecoded?(2)
        XCTAssertFalse(model.shouldPresentFullScreen)
        model.stopStreaming()
    }

    @MainActor
    func testTextFailureCannotBeOverwrittenByRemainingChunkAcknowledgements() async {
        let model = PadConnectionModel(startServices: false)
        let first = UUID(), second = UUID()
        model.pendingTextIDs = [first, second]
        let now = DispatchTime.now().uptimeNanoseconds
        _ = model.controlAcknowledgements.begin(id: first, at: now)
        _ = model.controlAcknowledgements.begin(id: second, at: now)
        model.handle(WireMessage(id: first, kind: .error, detail: "accessibility_permission_required"))
        model.handleControlAcknowledgement(WireMessage(id: second, kind: .controlAck))
        await Task.yield()
        XCTAssertTrue(model.pendingTextIDs.isEmpty)
        XCTAssertFalse(model.transferStatus.contains("文字已输入"))
    }

    func testAuthenticatedAudioReceiverRejectsSourceTakeover() async throws {
        let receiver = PadAudioReceiver()
        let generation = UUID(), stream = UUID()
        let key = VideoDatagramCrypto.makeKey()
        let ready = expectation(description: "声音接收端启动")
        let first = expectation(description: "第一包声音")
        let second = expectation(description: "合法来源保持")
        let port = SynchronizedValue<UInt16?>(nil)
        let received = SynchronizedValue<[UInt32]>([])
        receiver.onReady = { number, _ in port.set(number); ready.fulfill() }
        receiver.onPacket = { packet in
            received.mutate { $0.append(packet.sequence) }
            if packet.sequence == 1 { first.fulfill() }
            if packet.sequence == 2 { second.fulfill() }
        }
        receiver.onFailure = { reason, _ in XCTFail(reason) }
        receiver.start(generation: generation)
        defer { receiver.stop() }
        await fulfillment(of: [ready], timeout: 5)
        receiver.expect(streamID: stream, key: key)
        let endpoint = try XCTUnwrap(NWEndpoint.Port(rawValue: XCTUnwrap(port.value)))
        let normal = NWConnection(host: .ipv4(.loopback), port: endpoint, using: .udp)
        let foreign = NWConnection(host: .ipv4(.loopback), port: endpoint, using: .udp)
        let queue = DispatchQueue(label: "声音接收测试")
        normal.start(queue: queue); foreign.start(queue: queue)
        defer { normal.cancel(); foreign.cancel() }
        func packet(_ sequence: UInt32) throws -> Data {
            try VideoDatagramCrypto.seal(AudioPacketCodec.encode(AudioPacket(streamID: stream, sequence: sequence, pcm: Data(count: 960))), key: key)
        }
        normal.send(content: try packet(1), completion: .contentProcessed { XCTAssertNil($0) })
        await fulfillment(of: [first], timeout: 5)
        foreign.send(content: try packet(99), completion: .contentProcessed { XCTAssertNil($0) })
        try await Task.sleep(for: .milliseconds(100))
        normal.send(content: try packet(2), completion: .contentProcessed { XCTAssertNil($0) })
        await fulfillment(of: [second], timeout: 5)
        XCTAssertEqual(received.value, [1,2])
    }

    func testAudioPCMReachesRenderCompletion() async {
        let player = PadAudioPlayer()
        let played = expectation(description: "静音 PCM 已通过实际播放引擎")
        player.onFailure = { XCTFail($0) }
        player.onRendered = { played.fulfill() }
        player.enqueue(AudioPacket(streamID: UUID(), sequence: 1, pcm: Data(count: 960)))
        await fulfillment(of: [played], timeout: 5)
        player.stop()
    }
}
