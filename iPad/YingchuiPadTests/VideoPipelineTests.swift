import AVFoundation
import Network
import VideoToolbox
import XCTest
import YingchuiProtocol
@testable import YingchuiPad

private struct TestSample: @unchecked Sendable { let sample: CMSampleBuffer }

private enum FixtureError: Error { case failed(OSStatus) }

func encodedFixture() throws -> (sets: [Data], payload: Data) {
    let output = SynchronizedValue<TestSample?>(nil)
    let failure = SynchronizedValue<OSStatus>(noErr)
    var encoder: VTCompressionSession?
    var status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: 64, height: 64,
        codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil,
        compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &encoder)
    guard status == noErr, let encoder else { throw FixtureError.failed(status) }
    defer { VTCompressionSessionInvalidate(encoder) }
    status = VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    guard status == noErr else { throw FixtureError.failed(status) }
    var pixel: CVPixelBuffer?
    status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel)
    guard status == noErr, let pixel else { throw FixtureError.failed(status) }
    CVPixelBufferLockBaseAddress(pixel, [])
    if let address = CVPixelBufferGetBaseAddress(pixel) {
        memset(address, 0x40, CVPixelBufferGetDataSize(pixel))
    }
    CVPixelBufferUnlockBaseAddress(pixel, [])
    status = VTCompressionSessionEncodeFrame(encoder, imageBuffer: pixel,
        presentationTimeStamp: .zero, duration: CMTime(value: 1, timescale: 60),
        frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary, infoFlagsOut: nil
    ) { status, _, sample in
        failure.set(status)
        if let sample { output.set(TestSample(sample: sample)) }
    }
    guard status == noErr else { throw FixtureError.failed(status) }
    status = VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
    guard status == noErr, failure.value == noErr,
          let sample = output.value?.sample,
          let format = CMSampleBufferGetFormatDescription(sample),
          let block = CMSampleBufferGetDataBuffer(sample) else { throw FixtureError.failed(status) }
    var sets: [Data] = []
    for index in 0..<2 {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
            parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
        guard status == noErr, let pointer else { throw FixtureError.failed(status) }
        sets.append(Data(bytes: pointer, count: size))
    }
    var payload = Data(count: CMBlockBufferGetDataLength(block))
    status = payload.withUnsafeMutableBytes {
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
    }
    guard status == noErr else { throw FixtureError.failed(status) }
    return (sets, payload)
}

private func completedFrame(_ payload: Data, stream: UUID, id: UInt32, isKeyFrame: Bool = true) throws -> CompletedVideoFrame {
    var reassembler = VideoFrameReassembler()
    for datagram in try VideoDatagramCodec.fragment(accessUnit: payload, streamID: stream, frameID: id,
        presentationTimeMicroseconds: 1_000_000, isKeyFrame: isKeyFrame) {
        if let frame = reassembler.append(try VideoDatagramCodec.decode(datagram)) { return frame }
    }
    throw FixtureError.failed(-1)
}

final class VideoPipelineTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testDecoderAcceptsBoundedColdStartBurst() async throws {
        let fixture = try encodedFixture()
        let renderer = VideoRenderer()
        let stream = UUID()
        let decoded = expectation(description: "冷启动突发帧完成解码")
        decoded.expectedFulfillmentCount = 12
        renderer.onFrameDecoded = { _ in decoded.fulfill() }
        renderer.onFailure = { XCTFail($0) }
        try renderer.configure(streamID: stream, parameterSets: fixture.sets)
        for id in 1...12 {
            try renderer.enqueue(completedFrame(fixture.payload, stream: stream, id: UInt32(id)))
        }
        await fulfillment(of: [decoded], timeout: 5)
        renderer.reset()
    }

    @MainActor
    func testMissingInitialKeyFrameRequestsReplacementBeforeDecoding() async throws {
        let fixture = try encodedFixture()
        let renderer = VideoRenderer()
        let stream = UUID()
        let decoded = expectation(description: "补发的关键帧成功解码")
        var requests = 0
        renderer.onNeedsKeyFrame = { requests += 1 }
        renderer.onFrameDecoded = { _ in decoded.fulfill() }
        renderer.onFailure = { XCTFail($0) }
        try renderer.configure(streamID: stream, parameterSets: fixture.sets)
        for id in 1...3 {
            XCTAssertThrowsError(try renderer.enqueue(completedFrame(
                fixture.payload, stream: stream, id: UInt32(id), isKeyFrame: false
            ))) { error in
                guard case VideoRendererError.missingInitialKeyFrame = error else {
                    return XCTFail("缺少起始关键帧必须明确报错")
                }
            }
        }
        XCTAssertEqual(requests, 1, "普通帧不能触发关键帧请求风暴")
        try renderer.enqueue(completedFrame(fixture.payload, stream: stream, id: 4))
        await fulfillment(of: [decoded], timeout: 5)
        renderer.reset()
        try renderer.configure(streamID: stream, parameterSets: fixture.sets)
        XCTAssertThrowsError(try renderer.enqueue(completedFrame(
            fixture.payload, stream: stream, id: 1, isKeyFrame: false
        )))
        XCTAssertEqual(requests, 2, "重连后必须重新等待起始关键帧")
        renderer.reset()
    }

    @MainActor
    func testRealH264FrameReportsDecodeOnlyAfterCompletion() async throws {
        let fixture = try encodedFixture()
        let renderer = VideoRenderer()
        let layer = AVSampleBufferDisplayLayer()
        renderer.attach(layer, videoGravity: .resizeAspect)
        let stream = UUID()
        let decoded = expectation(description: "收到真实解码输出")
        var count = 0
        renderer.onFrameDecoded = { _ in count += 1; decoded.fulfill() }
        renderer.onFailure = { XCTFail($0) }
        try renderer.configure(streamID: stream, parameterSets: fixture.sets)
        try renderer.enqueue(completedFrame(fixture.payload, stream: stream, id: 1))
        XCTAssertEqual(count, 0, "提交压缩帧不能立即记为解码成功")
        await fulfillment(of: [decoded], timeout: 5)
        XCTAssertEqual(count, 1)
        renderer.reset()
    }

    @MainActor
    func testMalformedVideoReportsFailureWithoutDecodedCount() async throws {
        let fixture = try encodedFixture()
        let renderer = VideoRenderer()
        let stream = UUID()
        let failed = expectation(description: "损坏帧必须报错")
        renderer.onFrameDecoded = { _ in XCTFail("损坏帧不得计为解码成功") }
        renderer.onFailure = { _ in failed.fulfill() }
        try renderer.configure(streamID: stream, parameterSets: fixture.sets)
        do {
            try renderer.enqueue(completedFrame(Data([0, 0, 0, 2, 0xff, 0xff]), stream: stream, id: 1))
        } catch {
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 5)
        renderer.reset()
    }

    func testForeignUDPSenderCannotReplaceAuthenticatedSource() async throws {
        let receiver = PadVideoReceiver()
        let ready = expectation(description: "视频接收端口就绪")
        let first = expectation(description: "合法来源首帧")
        let second = expectation(description: "合法来源保持连接")
        let port = SynchronizedValue<UInt16?>(nil)
        let stream = UUID()
        let key = VideoDatagramCrypto.makeKey()
        let observed = SynchronizedValue<[UInt32]>([])
        receiver.onReady = { value, _ in port.set(value); ready.fulfill() }
        receiver.onFrame = { frame, _ in
            observed.mutate { $0.append(frame.frameID) }
            if frame.frameID == 1 { first.fulfill() }
            if frame.frameID == 2 { second.fulfill() }
        }
        receiver.start()
        defer { receiver.stop() }
        await fulfillment(of: [ready], timeout: 5)
        let endpointPort = try XCTUnwrap(NWEndpoint.Port(rawValue: XCTUnwrap(port.value)))
        receiver.expect(streamID: stream, videoKey: key)
        let legitimate = NWConnection(host: .ipv4(.loopback), port: endpointPort, using: .udp)
        let foreign = NWConnection(host: .ipv4(.loopback), port: endpointPort, using: .udp)
        let queue = DispatchQueue(label: "VideoPipelineTests")
        legitimate.start(queue: queue)
        foreign.start(queue: queue)
        defer { legitimate.cancel(); foreign.cancel() }
        func packet(_ id: UInt32) throws -> Data {
            let bytes = try VideoDatagramCodec.fragment(accessUnit: Data([1, 2, 3]), streamID: stream,
                frameID: id, presentationTimeMicroseconds: 1_000_000, isKeyFrame: true)
            return try VideoDatagramCrypto.seal(XCTUnwrap(bytes.first), key: key)
        }
        legitimate.send(content: try packet(1), completion: .contentProcessed { error in
            XCTAssertNil(error)
        })
        await fulfillment(of: [first], timeout: 5)
        // 即使重放拥有正确密钥的同流数据，也不得接管已认证的来源。
        foreign.send(content: try packet(99), completion: .contentProcessed { error in XCTAssertNil(error) })
        try await Task.sleep(for: .milliseconds(250))
        legitimate.send(content: try packet(2), completion: .contentProcessed { error in XCTAssertNil(error) })
        await fulfillment(of: [second], timeout: 5)
        XCTAssertEqual(observed.value, [1, 2])
    }
}

extension VideoPipelineTests {
    @MainActor
    func testModelDoesNotStartNetworkOrKeychainInTestRuntime() {
        let model = PadConnectionModel()
        XCTAssertEqual(model.statusText, "测试模式")
        XCTAssertNil(model.connection)
        XCTAssertNil(model.browser)
        XCTAssertNil(model.credentialStoreErrorText)
    }

    @MainActor
    func testResetRejectsPendingDecoderCallbacks() async throws {
        let fixture = try encodedFixture()
        let renderer = VideoRenderer()
        let stream = UUID()
        renderer.onFrameDecoded = { _ in XCTFail("已重置的旧帧不能更新新会话统计") }
        renderer.onFailure = { XCTFail($0) }
        try renderer.configure(streamID: stream, parameterSets: fixture.sets)
        try renderer.enqueue(completedFrame(fixture.payload, stream: stream, id: 1))
        renderer.reset()
        try await Task.sleep(for: .milliseconds(100))
    }
}

extension VideoPipelineTests {
    @MainActor
    func testVideoConfigurationDoesNotRenewExhaustedRecoveryBudget() async throws {
        let fixture = try encodedFixture()
        let model = PadConnectionModel(startServices: false)
        XCTAssertEqual(model.streamRecoveryPolicy.nextDelaySeconds(), 1)
        let configuration = WireMessage(kind: .videoConfig, streamID: UUID(), codec: "h264",
            width: 64, height: 64, frameRate: 60, bitRate: 1_000_000,
            parameterSets: fixture.sets.map { $0.base64EncodedString() },
            videoKey: VideoDatagramCrypto.makeKey().base64EncodedString())
        model.wantsStreaming = true
        model.videoRequestID.set(configuration.id)
        model.videoConfigurationPending = true
        model.handleVideoConfiguration(configuration)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.streamRecoveryPolicy.nextDelaySeconds(), 2)
        model.wantsStreaming = true
        model.videoRequestID.set(configuration.id)
        model.videoConfigurationPending = true
        model.handleVideoConfiguration(configuration)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.streamRecoveryPolicy.nextDelaySeconds(), 4)
        XCTAssertNil(model.streamRecoveryPolicy.nextDelaySeconds())
        model.videoRenderer.reset()
    }

    @MainActor
    func testCredentialStorageFailureNeverEnablesControl() async throws {
        let model = PadConnectionModel(startServices: false)
        model.connectedHostKey = UUID().uuidString
        model.pendingCertificateFingerprint = Data(repeating: 1, count: 32).base64EncodedString()
        let requestID = UUID()
        model.pendingPairRequestID = requestID
        model.handlePairResult(WireMessage(id: requestID, kind: .pairResult, accepted: true,
            sessionToken: Data(repeating: 2, count: 32).base64EncodedString()))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(model.isPaired)
        XCTAssertFalse(model.wantsStreaming)
        XCTAssertNotNil(model.credentialStoreErrorText)
        XCTAssertTrue(model.canResetCurrentHostTrust)
    }
}

extension VideoPipelineTests {
    @MainActor
    func testUnsolicitedPairResultCannotCreateTrust() async throws {
        let model = PadConnectionModel(startServices: false)
        model.connectedHostKey = UUID().uuidString
        model.pendingCertificateFingerprint = Data(repeating: 1, count: 32).base64EncodedString()
        model.handlePairResult(WireMessage(kind: .pairResult, accepted: true,
            sessionToken: Data(repeating: 2, count: 32).base64EncodedString()))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(model.isPaired)
        XCTAssertTrue(model.statusText.contains("未请求的配对结果"))
    }
}

extension VideoPipelineTests {
    @MainActor
    func testLostReferenceFramesWaitForKeyFrameBeforeResumingDecoder() async throws {
        let fixture = try encodedFixture()
        let renderer = VideoRenderer()
        let stream = UUID()
        let first = expectation(description: "首帧正常解码")
        let recovered = expectation(description: "丢帧后关键帧恢复解码")
        var ids: [UInt32] = []
        var requests = 0
        renderer.onFrameDecoded = { id in
            ids.append(id)
            if id == 1 { first.fulfill() }
            if id == 5 { recovered.fulfill() }
        }
        renderer.onNeedsKeyFrame = { requests += 1 }
        renderer.onFailure = { XCTFail($0) }
        try renderer.configure(streamID: stream, parameterSets: fixture.sets)
        defer { renderer.reset() }
        try renderer.enqueue(completedFrame(fixture.payload, stream: stream, id: 1))
        await fulfillment(of: [first], timeout: 5)
        for id: UInt32 in [3, 4] {
            XCTAssertThrowsError(try renderer.enqueue(completedFrame(fixture.payload, stream: stream, id: id, isKeyFrame: false))) {
                guard case VideoRendererError.missingInitialKeyFrame = $0 else { return XCTFail("错误的恢复状态：\($0)") }
            }
        }
        XCTAssertEqual(requests, 1)
        try renderer.enqueue(completedFrame(fixture.payload, stream: stream, id: 5))
        await fulfillment(of: [recovered], timeout: 5)
        XCTAssertEqual(ids, [1, 5])
    }

    func testUDPGapDoesNotDeliverBrokenFramesOrDiscardRecoveringKeyFrame() async throws {
        let receiver = PadVideoReceiver()
        let ready = expectation(description: "丢包测试接收端就绪")
        let first = expectation(description: "首个关键帧收到")
        let final = expectation(description: "参考链恢复")
        let port = SynchronizedValue<UInt16?>(nil)
        let ids = SynchronizedValue<[UInt32]>([])
        let requests = SynchronizedValue(0)
        let stream = UUID(), key = VideoDatagramCrypto.makeKey()
        receiver.onReady = { value, _ in port.set(value); ready.fulfill() }
        receiver.onFrame = { frame, _ in
            ids.mutate { $0.append(frame.frameID) }
            if frame.frameID == 1 { first.fulfill() }
            if frame.frameID == 6 { final.fulfill() }
        }
        receiver.onNeedsKeyFrame = { requests.mutate { $0 += 1 } }
        receiver.start()
        defer { receiver.stop() }
        await fulfillment(of: [ready], timeout: 5)
        receiver.expect(streamID: stream, videoKey: key)
        let sender = NWConnection(host: .ipv4(.loopback), port: try XCTUnwrap(NWEndpoint.Port(rawValue: XCTUnwrap(port.value))), using: .udp)
        sender.start(queue: DispatchQueue(label: "视频丢包测试"))
        defer { sender.cancel() }
        func packets(_ id: UInt32, keyFrame: Bool, size: Int = 10) throws -> [Data] {
            try VideoDatagramCodec.fragment(accessUnit: Data(repeating: 1, count: size), streamID: stream,
                frameID: id, presentationTimeMicroseconds: UInt64(id) * 16_667, isKeyFrame: keyFrame)
                .map { try VideoDatagramCrypto.seal($0, key: key) }
        }
        func send(_ packets: [Data]) async throws {
            for packet in packets {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    sender.send(content: packet, completion: .contentProcessed { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    })
                }
            }
        }
        try await send(packets(1, keyFrame: true))
        await fulfillment(of: [first], timeout: 5)
        // 丢失 2，3 和 4 不能再解码；恢复帧 5 的尾部分片比普通帧 6 晚到。
        try await send(packets(3, keyFrame: false))
        try await send(packets(4, keyFrame: false))
        try await Task.sleep(for: .milliseconds(60))
        let replacement = try packets(5, keyFrame: true, size: 4_000)
        try await send([XCTUnwrap(replacement.first)])
        try await send(packets(6, keyFrame: false))
        try await send(Array(replacement.dropFirst()))
        try await send(packets(6, keyFrame: false))
        await fulfillment(of: [final], timeout: 5)
        XCTAssertEqual(ids.value, [1, 5, 6])
        XCTAssertGreaterThan(requests.value, 0)
    }
}
