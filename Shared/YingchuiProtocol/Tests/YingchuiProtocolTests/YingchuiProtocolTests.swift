import Foundation
import Testing
@testable import YingchuiProtocol

@Test func decodesAFrameArrivingInChunks() throws {
    let original = WireMessage(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        kind: .ping,
        sentAtMilliseconds: 123
    )
    let frame = try WireCodec.encode(original)
    var decoder = WireMessageDecoder()

    #expect(try decoder.append(frame.prefix(2)).isEmpty)
    #expect(try decoder.append(frame.dropFirst(2)) == [original])
}

@Test func decodesMultipleFramesFromOnePacket() throws {
    let first = WireMessage(kind: .hello, deviceName: "iPad")
    let second = WireMessage(kind: .pong)
    var packet = try WireCodec.encode(first)
    packet.append(try WireCodec.encode(second))
    var decoder = WireMessageDecoder()

    #expect(try decoder.append(packet) == [first, second])
}

@Test func preservesPairingAndControlFields() throws {
    let pairing = WireMessage(
        kind: .pairRequest,
        deviceName: "测试 iPad",
        deviceID: "device-001",
        pairingCode: "123456"
    )
    let pointer = WireMessage(
        kind: .pointerMove,
        deltaX: 12.5,
        deltaY: -3.25
    )
    let shortcut = WireMessage(
        kind: .keyPress,
        key: .letterZ,
        modifiers: [.command, .shift]
    )
    var decoder = WireMessageDecoder()

    let decodedPairing = try decoder.append(WireCodec.encode(pairing))
    let decodedPointer = try decoder.append(WireCodec.encode(pointer))
    let decodedShortcut = try decoder.append(WireCodec.encode(shortcut))

    #expect(decodedPairing == [pairing])
    #expect(decodedPointer == [pointer])
    #expect(decodedShortcut == [shortcut])
}

@Test func preservesStableHostIdentityAndControlAcknowledgement() throws {
    let hostID = "3B1299E0-2FA2-40B3-9679-885300ACE02D"
    let hello = WireMessage(kind: .hello, deviceName: "Mac mini", hostID: hostID, accepted: true)
    let acknowledgement = WireMessage(id: UUID(), kind: .controlAck)

    var decoder = WireMessageDecoder()
    #expect(try decoder.append(WireCodec.encode(hello)) == [hello])
    #expect(try decoder.append(WireCodec.encode(acknowledgement)) == [acknowledgement])
    #expect(hello.hostID == hostID)
}

@Test func remoteButtonStateReturnsPressedButtonsExactlyOnce() {
    var state = RemoteButtonState()
    state.record(.left, pressed: true)
    state.record(.right, pressed: true)
    state.record(.right, pressed: false)

    #expect(state.takePressedButtons() == [.left])
    #expect(state.isEmpty)
    #expect(state.takePressedButtons().isEmpty)
}

@Test func diagnosticEventLogKeepsOnlyNewestEntries() {
    let log = DiagnosticEventLog(
        subsystem: "com.yingchui.interconnect.tests",
        category: "诊断测试",
        capacity: 2
    )
    log.record("第一条")
    log.record("第二条")
    log.record("第三条")

    #expect(log.recentMessages(limit: 10) == ["第二条", "第三条"])
}

@Test func controlAcknowledgementTrackerExpiresAndMeasuresCommands() {
    let completedID = UUID()
    let expiredID = UUID()
    var tracker = ControlAcknowledgementTracker()
    tracker.begin(id: expiredID, at: 1_000_000)
    #expect(tracker.expire(at: 6_002_000_000) == 1)
    #expect(tracker.begin(id: completedID, at: 6_002_000_000) == 0)
    #expect(tracker.acknowledge(id: completedID, at: 6_005_500_000) == 3.5)
    #expect(tracker.acknowledge(id: expiredID, at: 6_005_500_000) == nil)
    tracker.begin(id: completedID, at: 7_000_000_000)
    let didCancel = tracker.cancel(id: completedID)
    #expect(didCancel)
    #expect(tracker.acknowledge(id: completedID, at: 7_001_000_000) == nil)
}

@Test func hostAdvertisementRequiresStableIdentityAndVersion() {
    let hostID = "3B1299E0-2FA2-40B3-9679-885300ACE02D"
    let advertisement = HostAdvertisement(hostID: hostID)

    #expect(HostAdvertisement(txtRecord: advertisement.txtRecord) == advertisement)
    #expect(HostAdvertisement(txtRecord: [HostAdvertisement.protocolVersionKey: "5"]) == nil)
    #expect(HostAdvertisement(txtRecord: [
        HostAdvertisement.hostIDKey: "无效身份",
        HostAdvertisement.protocolVersionKey: "5"
    ]) == nil)
}

@Test func keyFrameReplicationStaysWithinOutstandingDatagramLimit() {
    #expect(VideoPacketReplicationPolicy.copiesPerFragment(
        isKeyFrame: true,
        fragmentCount: 300
    ) == 2)
    #expect(VideoPacketReplicationPolicy.copiesPerFragment(
        isKeyFrame: true,
        fragmentCount: 600
    ) == 1)
    #expect(VideoPacketReplicationPolicy.copiesPerFragment(
        isKeyFrame: false,
        fragmentCount: 300
    ) == 1)
}

@Test func reassemblerIgnoresReplicatedPacketsAfterFrameCompletion() throws {
    let streamID = UUID()
    let datagrams = try VideoDatagramCodec.fragment(
        accessUnit: Data(repeating: 9, count: VideoDatagramCodec.maximumPayloadSize * 2),
        streamID: streamID,
        frameID: 88,
        presentationTimeMicroseconds: 900,
        isKeyFrame: true
    )
    var reassembler = VideoFrameReassembler()
    var completedFrames = 0

    for datagram in datagrams {
        let fragment = try VideoDatagramCodec.decode(datagram)
        if reassembler.append(fragment) != nil { completedFrames += 1 }
        if reassembler.append(fragment) != nil { completedFrames += 1 }
    }

    #expect(completedFrames == 1)
    #expect(reassembler.discardIncompleteFrames(olderThanUptimeNanoseconds: .max) == 0)
}

@Test func remoteControlValidationClampsPointerAndScrollDeltas() throws {
    let pointer = try RemoteControlValidator.command(
        from: WireMessage(kind: .pointerMove, deltaX: 900, deltaY: -700)
    )
    let scroll = try RemoteControlValidator.command(
        from: WireMessage(kind: .scroll, deltaX: -450, deltaY: 800)
    )

    #expect(pointer == .pointerMove(deltaX: 500, deltaY: -500))
    #expect(scroll == .scroll(deltaX: -300, deltaY: 300))
}

@Test func remoteControlValidationRejectsIncompleteAndInvalidCoordinates() {
    #expect(throws: RemoteControlValidationError.missingField) {
        _ = try RemoteControlValidator.command(from: WireMessage(kind: .mouseButton, button: .left))
    }
    #expect(throws: RemoteControlValidationError.invalidCoordinate) {
        _ = try RemoteControlValidator.command(
            from: WireMessage(kind: .pointerMove, deltaX: .nan, deltaY: 1)
        )
    }
}

@Test func remoteControlValidationLimitsTextAndPreservesShortcuts() throws {
    let text = try RemoteControlValidator.command(
        from: WireMessage(kind: .textInput, text: String(repeating: "鹰", count: 128))
    )
    let shortcut = try RemoteControlValidator.command(
        from: WireMessage(kind: .keyPress, key: .letterZ, modifiers: [.command, .shift])
    )

    guard case .textInput(let value) = text else {
        Issue.record("文字输入验证返回了错误的指令类型")
        return
    }
    #expect(value.count == 128)
    #expect(shortcut == .keyPress(.letterZ, modifiers: [.command, .shift]))
}

@Test func preservesVideoConfigurationFields() throws {
    let streamID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    let config = WireMessage(
        kind: .videoConfig,
        streamID: streamID,
        codec: "h264",
        width: 1920,
        height: 1080,
        frameRate: 60,
        bitRate: 8_000_000,
        parameterSets: [Data([1, 2, 3]).base64EncodedString()],
        videoKey: Data(repeating: 7, count: 32).base64EncodedString()
    )
    var decoder = WireMessageDecoder()

    #expect(try decoder.append(WireCodec.encode(config)) == [config])
}

@Test func fragmentsAndReassemblesVideoOutOfOrder() throws {
    let streamID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    let accessUnit = Data((0..<5_000).map { UInt8($0 % 251) })
    let datagrams = try VideoDatagramCodec.fragment(
        accessUnit: accessUnit,
        streamID: streamID,
        frameID: 42,
        presentationTimeMicroseconds: 123_456,
        isKeyFrame: true
    )
    var reassembler = VideoFrameReassembler()
    var completed: CompletedVideoFrame?

    for datagram in datagrams.reversed() {
        let fragment = try VideoDatagramCodec.decode(datagram)
        completed = reassembler.append(fragment) ?? completed
        #expect(datagram.count <= VideoDatagramCodec.maximumDatagramSize)
    }

    #expect(completed?.streamID == streamID)
    #expect(completed?.frameID == 42)
    #expect(completed?.presentationTimeMicroseconds == 123_456)
    #expect(completed?.isKeyFrame == true)
    #expect(completed?.accessUnit == accessUnit)
}

@Test func expiresIncompleteVideoFrames() throws {
    let streamID = UUID(uuidString: "20000000-0000-0000-0000-000000000003")!
    let datagrams = try VideoDatagramCodec.fragment(
        accessUnit: Data(repeating: 8, count: 3_000),
        streamID: streamID,
        frameID: 7,
        presentationTimeMicroseconds: 1,
        isKeyFrame: false
    )
    var reassembler = VideoFrameReassembler()
    let fragment = try VideoDatagramCodec.decode(datagrams[0])

    #expect(reassembler.append(fragment, receivedAtUptimeNanoseconds: 100) == nil)
    #expect(reassembler.discardIncompleteFrames(olderThanUptimeNanoseconds: 99) == 0)
    #expect(reassembler.discardIncompleteFrames(olderThanUptimeNanoseconds: 101) == 1)
}

@Test func reassemblerEvictsByArrivalAgeInsteadOfFrameNumber() throws {
    let streamID = UUID(uuidString: "20000000-0000-0000-0000-000000000004")!
    let payload = Data(repeating: 4, count: VideoDatagramCodec.maximumPayloadSize + 10)
    func fragments(frameID: UInt32) throws -> [VideoFragment] {
        try VideoDatagramCodec.fragment(
            accessUnit: payload,
            streamID: streamID,
            frameID: frameID,
            presentationTimeMicroseconds: UInt64(frameID),
            isKeyFrame: false
        ).map(VideoDatagramCodec.decode)
    }

    let oldest = try fragments(frameID: 100)
    let newerLowNumber = try fragments(frameID: 1)
    let newest = try fragments(frameID: 50)
    var reassembler = VideoFrameReassembler(maximumPendingFrames: 2)

    #expect(reassembler.append(oldest[0], receivedAtUptimeNanoseconds: 100) == nil)
    #expect(reassembler.append(newerLowNumber[0], receivedAtUptimeNanoseconds: 200) == nil)
    #expect(reassembler.append(newest[0], receivedAtUptimeNanoseconds: 300) == nil)
    #expect(reassembler.append(newerLowNumber[1], receivedAtUptimeNanoseconds: 400)?.frameID == 1)
}

@Test func streamProfilesPreserveViewportAspectRatio() {
    let landscape = StreamDimensions(width: 2_752, height: 2_064)
    let portrait = StreamDimensions(width: 2_064, height: 2_752)

    #expect(StreamRequest(quality: .smooth, viewport: landscape).viewport == landscape)
    #expect(StreamRequest(quality: .smooth, viewport: landscape).dimensions == .init(width: 1_280, height: 960))
    #expect(StreamRequest(quality: .balanced, viewport: landscape).dimensions == .init(width: 1_920, height: 1_440))
    #expect(StreamRequest(quality: .sharp, viewport: landscape).dimensions == .init(width: 2_560, height: 1_920))
    #expect(StreamRequest(quality: .native, viewport: landscape).dimensions == landscape)
    #expect(StreamRequest(quality: .balanced, viewport: portrait).dimensions == .init(width: 1_440, height: 1_920))
}

@Test func nativeStreamUsesTheDisplayMaximumRefreshRate() {
    let viewport = StreamDimensions(width: 2_752, height: 2_064)
    let sixtyHertz = StreamRequest(
        quality: .native,
        viewport: viewport,
        maximumFrameRate: 60
    )
    let ninetyHertz = StreamRequest(
        quality: .native,
        viewport: viewport,
        maximumFrameRate: 90
    )
    let oneHundredTwentyHertz = StreamRequest(
        quality: .native,
        viewport: viewport,
        maximumFrameRate: 120
    )

    #expect(sixtyHertz.frameRate == 60)
    #expect(sixtyHertz.bitRate == 30_000_000)
    #expect(ninetyHertz.frameRate == 90)
    #expect(ninetyHertz.bitRate == 45_000_000)
    #expect(oneHundredTwentyHertz.frameRate == 120)
    #expect(oneHundredTwentyHertz.bitRate == 60_000_000)
}

@Test func nonNativeProfilesRemainWithinTheirFrameRateBudget() {
    let viewport = StreamDimensions(width: 2_752, height: 2_064)

    #expect(
        StreamRequest(
            quality: .smooth,
            viewport: viewport,
            maximumFrameRate: 120
        ).frameRate == 30
    )
    #expect(
        StreamRequest(
            quality: .sharp,
            viewport: viewport,
            maximumFrameRate: 120
        ).frameRate == 60
    )
}

@Test func resolutionOptionsUseOnlyDistinctPixelDimensions() {
    let largeViewport = StreamDimensions(width: 2_752, height: 2_064)
    let compactViewport = StreamDimensions(width: 2_420, height: 1_668)

    #expect(StreamQualityPreset.resolutionOptions(viewport: largeViewport) == StreamQualityPreset.allCases)
    #expect(
        StreamQualityPreset.resolutionOptions(viewport: compactViewport) == [
            .smooth,
            .balanced,
            .native
        ]
    )
}

@Test func videoOutputSizingPreservesNativePixelsWithoutUpscaling() {
    let request = VideoOutputSizingPolicy.normalizedRequest(
        StreamDimensions(width: 2_752, height: 2_064)
    )
    let output = VideoOutputSizingPolicy.aspectFit(
        source: StreamDimensions(width: 2_560, height: 1_600),
        within: request
    )

    #expect(request == StreamDimensions(width: 2_752, height: 2_064))
    #expect(output == StreamDimensions(width: 2_560, height: 1_600))
}

@Test func videoOutputSizingConvertsRetinaPointsToNativePixels() {
    let nativePixels = VideoOutputSizingPolicy.nativePixelDimensions(
        pointWidth: 1_728,
        pointHeight: 1_117,
        pointPixelScale: 2
    )

    #expect(nativePixels == StreamDimensions(width: 3_456, height: 2_234))
    #expect(
        VideoOutputSizingPolicy.nativePixelDimensions(
            pointWidth: 1_728,
            pointHeight: 1_117,
            pointPixelScale: 0
        ) == nil
    )
}

@Test func videoOutputSizingFitsWideAndPortraitSourcesWithoutCropping() {
    let wide = VideoOutputSizingPolicy.aspectFit(
        source: StreamDimensions(width: 3_456, height: 2_234),
        within: StreamDimensions(width: 2_752, height: 2_064)
    )
    let portrait = VideoOutputSizingPolicy.aspectFit(
        source: StreamDimensions(width: 2_160, height: 3_840),
        within: StreamDimensions(width: 2_064, height: 2_752)
    )

    #expect(wide == StreamDimensions(width: 2_752, height: 1_778))
    #expect(portrait == StreamDimensions(width: 1_548, height: 2_752))
    #expect(abs(Double(wide.width) / Double(wide.height) - 3_456.0 / 2_234.0) < 0.002)
    #expect(abs(Double(portrait.width) / Double(portrait.height) - 2_160.0 / 3_840.0) < 0.002)
}

@Test func videoOutputSizingEnforcesFourKEncoderBudget() {
    let output = VideoOutputSizingPolicy.normalizedRequest(
        StreamDimensions(width: 5_000, height: 5_000)
    )

    #expect(output == StreamDimensions(width: 2_880, height: 2_880))
    #expect(output.width <= VideoOutputSizingPolicy.maximumSide)
    #expect(output.height <= VideoOutputSizingPolicy.maximumSide)
    #expect(output.width * output.height <= VideoOutputSizingPolicy.maximumPixelCount)
}

@Test func adaptiveStreamPolicyDegradesWithHysteresis() {
    var policy = AdaptiveStreamPolicy()
    policy.reset(ceiling: .native)

    #expect(policy.evaluate(lossRate: 0.03, roundTripP95Milliseconds: 10, videoLatencyP95Milliseconds: 40) == nil)
    #expect(policy.evaluate(lossRate: 0.03, roundTripP95Milliseconds: 10, videoLatencyP95Milliseconds: 40) == .sharp)
    #expect(policy.evaluate(lossRate: 0.06, roundTripP95Milliseconds: 10, videoLatencyP95Milliseconds: 40) == .balanced)
    #expect(policy.current == .balanced)
}

@Test func adaptiveStreamPolicyRecoversWithoutExceedingCeiling() {
    var policy = AdaptiveStreamPolicy()
    policy.reset(ceiling: .sharp)
    #expect(policy.evaluateStall() == .balanced)

    for _ in 0..<7 {
        #expect(policy.evaluate(lossRate: 0, roundTripP95Milliseconds: 10, videoLatencyP95Milliseconds: 40) == nil)
    }
    #expect(policy.evaluate(lossRate: 0, roundTripP95Milliseconds: 10, videoLatencyP95Milliseconds: 40) == .sharp)

    for _ in 0..<8 {
        #expect(policy.evaluate(lossRate: 0, roundTripP95Milliseconds: 10, videoLatencyP95Milliseconds: 40) == nil)
    }
    #expect(policy.current == .sharp)
}

@Test func streamRecoveryPolicyUsesBoundedExponentialRetries() {
    var policy = StreamRecoveryPolicy(maximumAttempts: 3)

    #expect(policy.nextDelaySeconds() == 1)
    #expect(policy.nextDelaySeconds() == 2)
    #expect(policy.nextDelaySeconds() == 4)
    #expect(policy.nextDelaySeconds() == nil)

    policy.reset()
    #expect(policy.nextDelaySeconds() == 1)
}

@Test func synchronizedValueSerializesConcurrentMutation() async {
    let value = SynchronizedValue(0)

    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<1_000 {
            group.addTask {
                value.mutate { $0 += 1 }
            }
        }
    }

    #expect(value.value == 1_000)
}

@Test func adaptiveBitRatePolicyUsesLossHysteresis() {
    var policy = AdaptiveBitRatePolicy(maximumBitRate: 16_000_000)

    #expect(policy.evaluate(lossRate: 0.03) == nil)
    #expect(policy.evaluate(lossRate: 0.03) == 13_600_000)
    #expect(policy.evaluate(lossRate: 0.06) == 10_200_000)
    #expect(policy.currentBitRate == 10_200_000)
}

@Test func adaptiveBitRatePolicyRecoversToConfiguredCeiling() {
    var policy = AdaptiveBitRatePolicy(maximumBitRate: 10_000_000)
    #expect(policy.evaluate(lossRate: 0.06) == 7_500_000)

    for _ in 0..<7 {
        #expect(policy.evaluate(lossRate: 0) == nil)
    }
    #expect(policy.evaluate(lossRate: 0) == 8_625_000)

    for _ in 0..<24 {
        _ = policy.evaluate(lossRate: 0)
    }
    #expect(policy.currentBitRate == 10_000_000)
    #expect(policy.evaluate(lossRate: 0) == nil)
}

@Test func adaptiveBitRatePolicyPreservesConfiguredQualityFloor() {
    var policy = AdaptiveBitRatePolicy(
        maximumBitRate: 30_000_000,
        minimumBitRate: 17_000_000
    )

    #expect(policy.evaluate(lossRate: 0.06) == 22_500_000)
    #expect(policy.evaluate(lossRate: 0.06) == 17_000_000)
    #expect(policy.evaluate(lossRate: 0.06) == nil)
    #expect(policy.currentBitRate == 17_000_000)

    policy.restore(currentBitRate: 1_000_000)
    #expect(policy.currentBitRate == 17_000_000)
}

@Test func videoBitRateFloorScalesWithNativePixelLoad() {
    #expect(
        VideoBitRateFloorPolicy.minimumBitRate(
            dimensions: StreamDimensions(width: 2_224, height: 1_668),
            frameRate: 60,
            maximumBitRate: 30_000_000
        ) == 17_000_000
    )
    #expect(
        VideoBitRateFloorPolicy.minimumBitRate(
            dimensions: StreamDimensions(width: 2_752, height: 2_064),
            frameRate: 60,
            maximumBitRate: 30_000_000
        ) == 26_000_000
    )
    #expect(
        VideoBitRateFloorPolicy.minimumBitRate(
            dimensions: StreamDimensions(width: 1_280, height: 960),
            frameRate: 30,
            maximumBitRate: 6_000_000
        ) == 4_000_000
    )
    #expect(
        VideoBitRateFloorPolicy.minimumBitRate(
            dimensions: StreamDimensions(width: 2_752, height: 2_064),
            frameRate: 120,
            maximumBitRate: 60_000_000
        ) == 51_500_000
    )
}

@Test func rejectsMalformedVideoDatagram() {
    #expect(throws: VideoDatagramError.datagramTooShort) {
        _ = try VideoDatagramCodec.decode(Data([0, 1, 2]))
    }
}

@Test func rejectsEmptyAndOversizedControlFrames() {
    var emptyDecoder = WireMessageDecoder()
    #expect(throws: WireCodecError.emptyFrame) {
        _ = try emptyDecoder.append(Data(repeating: 0, count: 4))
    }

    var oversizedLength = UInt32(YingchuiService.maximumFrameSize + 1).bigEndian
    let oversizedHeader = Data(bytes: &oversizedLength, count: MemoryLayout<UInt32>.size)
    var oversizedDecoder = WireMessageDecoder()
    #expect(throws: WireCodecError.frameTooLarge(YingchuiService.maximumFrameSize + 1)) {
        _ = try oversizedDecoder.append(oversizedHeader)
    }
}

@Test func encryptsAndAuthenticatesVideoDatagrams() throws {
    let key = VideoDatagramCrypto.makeKey()
    let plaintext = Data((0..<VideoDatagramCodec.maximumDatagramSize).map { UInt8($0 % 251) })
    let sealed = try VideoDatagramCrypto.seal(plaintext, key: key)

    #expect(sealed != plaintext)
    #expect(sealed.count <= VideoDatagramCodec.maximumWireDatagramSize)
    #expect(try VideoDatagramCrypto.open(sealed, key: key) == plaintext)

    var tampered = sealed
    tampered[tampered.count - 1] ^= 1
    #expect(throws: VideoDatagramCryptoError.authenticationFailed) {
        _ = try VideoDatagramCrypto.open(tampered, key: key)
    }
}

@Test func protocolErrorsProvideLocalizedDiagnostics() {
    #expect(VideoDatagramError.datagramTooShort.localizedDescription == "视频数据包长度不足")
    #expect(VideoDatagramCryptoError.authenticationFailed.localizedDescription == "视频数据包认证失败或已损坏")
    #expect(WireCodecError.emptyFrame.localizedDescription == "控制消息不能为空")
}

@Test func enforcesVideoDatagramAndFrameMemoryLimits() throws {
    let streamID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
    let oversizedAccessUnit = Data(repeating: 1, count: VideoDatagramCodec.maximumAccessUnitSize + 1)
    #expect(throws: VideoDatagramError.accessUnitTooLarge(oversizedAccessUnit.count)) {
        _ = try VideoDatagramCodec.fragment(
            accessUnit: oversizedAccessUnit,
            streamID: streamID,
            frameID: 1,
            presentationTimeMicroseconds: 1,
            isKeyFrame: false
        )
    }

    let invalidFragment = VideoFragment(
        streamID: streamID,
        frameID: 2,
        fragmentIndex: 0,
        fragmentCount: UInt16(VideoDatagramCodec.maximumFragmentsPerFrame + 1),
        presentationTimeMicroseconds: 2,
        isKeyFrame: false,
        payload: Data([1])
    )
    #expect(throws: VideoDatagramError.invalidHeader) {
        _ = try VideoDatagramCodec.decode(VideoDatagramCodec.encode(invalidFragment))
    }
    var reassembler = VideoFrameReassembler()
    #expect(reassembler.append(invalidFragment) == nil)

    let key = VideoDatagramCrypto.makeKey()
    #expect(throws: VideoDatagramCryptoError.datagramTooLarge) {
        _ = try VideoDatagramCrypto.open(
            Data(repeating: 0, count: VideoDatagramCodec.maximumWireDatagramSize + 1),
            key: key
        )
    }
}
