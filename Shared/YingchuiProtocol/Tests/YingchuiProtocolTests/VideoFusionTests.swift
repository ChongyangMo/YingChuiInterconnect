import Foundation
import Testing
@testable import YingchuiProtocol

@Test func videoFusionRequiresBothSidesToOfferHEVC() throws {
    let size = StreamDimensions(width: 2732, height: 2048)
    let both = [VideoDecodeCapability(codec: .h264), VideoDecodeCapability(codec: .hevc)]
    let preferred = try VideoStreamNegotiation.select(dimensions: size, frameRate: 120,
        bitRate: 60_000_000, capabilities: both, hardwareHEVC: true)
    #expect(preferred.codec == .hevc)
    #expect(preferred.frameRate == 120)
    #expect(preferred.dimensions == size)
    let unsupportedSender = try VideoStreamNegotiation.select(dimensions: size, frameRate: 120,
        bitRate: 60_000_000, capabilities: both, hardwareHEVC: false)
    #expect(unsupportedSender.codec == .h264)
    #expect(unsupportedSender.frameRate < 120)
    let legacy = try VideoStreamNegotiation.select(dimensions: size, frameRate: 60,
        bitRate: 10_000_000, capabilities: nil, hardwareHEVC: true)
    #expect(legacy.codec == .h264)
}

@Test func videoFusionPreservesResolutionAndRespectsReceiverThroughput() throws {
    let size = StreamDimensions(width: 1920, height: 1080)
    let limited = VideoDecodeCapability(codec: .h264, maximumPixelsPerSecond: 1920 * 1080 * 30)
    let chosen = try VideoStreamNegotiation.select(dimensions: size, frameRate: 60,
        bitRate: 10_000_000, capabilities: [limited], hardwareHEVC: false)
    #expect(chosen.dimensions == size)
    #expect(chosen.frameRate == 30)
    let tooSmall = VideoDecodeCapability(codec: .h264, maximumWidth: 1280)
    #expect(throws: VideoNegotiationError.self) {
        try VideoStreamNegotiation.select(dimensions: size, frameRate: 60, bitRate: 10_000_000,
            capabilities: [tooSmall], hardwareHEVC: false)
    }
    #expect(throws: VideoNegotiationError.self) {
        try VideoStreamNegotiation.select(dimensions: size, frameRate: 60, bitRate: 10_000_000,
            capabilities: [], hardwareHEVC: true)
    }
}

@Test func videoFusionBackpressureRejectsBeforeEncodingAndIgnoresOldTickets() throws {
    var admission = VideoPipelineAdmission()
    let firstTicket = admission.admit(queuedPackets: 0, oldestQueuedAgeNanoseconds: 0)
    let first = try #require(firstTicket)
    let blocked = admission.admit(queuedPackets: 0, oldestQueuedAgeNanoseconds: 0)
    #expect(blocked == nil)
    admission.reset()
    let nextTicket = admission.admit(queuedPackets: 0, oldestQueuedAgeNanoseconds: 0)
    let next = try #require(nextTicket)
    let obsolete = admission.complete(first)
    #expect(!obsolete)
    #expect(admission.pendingEncodes == 1)
    let completed = admission.complete(next)
    #expect(completed)
    let full = admission.admit(queuedPackets: 128, oldestQueuedAgeNanoseconds: 0)
    let stale = admission.admit(queuedPackets: 1, oldestQueuedAgeNanoseconds: 32_000_000)
    #expect(full == nil)
    #expect(stale == nil)
    #expect(admission.pendingEncodes == 0)
}

@Test func videoFusionProtocolCompatibilityDoesNotLowerTheExistingFloor() {
    #expect(WireProtocolCompatibility.negotiatedVersion(peerVersion: 9, peerMinimum: nil) == 9)
    #expect(WireProtocolCompatibility.negotiatedVersion(peerVersion: 10, peerMinimum: 9) == 9)
    #expect(WireProtocolCompatibility.negotiatedVersion(peerVersion: 10, peerMinimum: nil) == nil)
    #expect(WireProtocolCompatibility.negotiatedVersion(peerVersion: 8, peerMinimum: 8) == nil)
    #expect(WireProtocolCompatibility.negotiatedVersion(peerVersion: 9, peerMinimum: 10) == nil)
    let advertisement = HostAdvertisement(hostID: UUID().uuidString, protocolVersion: 10, minimumProtocolVersion: 9)
    #expect(advertisement.isCompatible)
    #expect(HostAdvertisement(txtRecord: advertisement.txtRecord) == advertisement)
}

@Test func videoFusionUnknownOptionalMessagesCannotDiscardFollowingKnownFrames() throws {
    let ping = WireMessage(kind: .ping)
    var future = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ping)) as? [String: Any])
    future["kind"] = "futureOptionalMessage"
    let payload = try JSONSerialization.data(withJSONObject: future)
    var count = UInt32(payload.count).bigEndian
    var packet = Data(bytes: &count, count: 4)
    packet.append(payload)
    packet.append(try WireCodec.encode(ping))
    var decoder = WireMessageDecoder()
    #expect(try decoder.append(packet) == [ping])
    let request = WireMessage(kind: .streamStart, minimumProtocolVersion: 9,
        videoCapabilities: [.init(codec: .hevc)])
    #expect(try decoder.append(WireCodec.encode(request)) == [request])
}
