import Foundation
import XCTest
@testable import YingchuiProtocol

final class USBPacketTests: XCTestCase {
    func testSplitAndJoinedFramesPreserveControlAndEncryptedPayloadBytes() throws {
        let payload = try WireCodec.encode(WireMessage(kind: .ping))
        let control = try USBPacketCodec.encode(USBPacket(kind: .control, payload: payload))
        let video = try USBPacketCodec.encode(USBPacket(kind: .video, payload: payload))
        var decoder = USBPacketDecoder()
        XCTAssertTrue(try decoder.append(control.prefix(3)).isEmpty)
        let packets = try decoder.append(Data(control.dropFirst(3)) + video)
        XCTAssertEqual(packets.map(\.kind), [.control, .video])
        XCTAssertEqual(packets.map(\.payload), [payload, payload])
    }
    func testMalformedAndExcessivePacketsAreRejected() throws {
        var decoder = USBPacketDecoder()
        XCTAssertThrowsError(try decoder.append(Data([0x7f, 0xff, 0xff, 0xff, 3])))
        XCTAssertThrowsError(try USBPacketCodec.encode(USBPacket(kind: .video, payload: Data())))
        XCTAssertThrowsError(try USBPacketCodec.encode(USBPacket(kind: .video, payload: Data(count: 65_537))))
    }
    func testIntroductionCannotOverrideTransportOrProtocolValidation() throws {
        let introduction = USBHostIntroduction(hostID: UUID().uuidString, name: "Mac")
        let data = try JSONEncoder().encode(introduction)
        XCTAssertEqual(try USBHostIntroduction.decode(data).hostID, introduction.hostID)
        let invalid = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "YingchuiUSB1", with: "wrong").utf8)
        XCTAssertThrowsError(try USBHostIntroduction.decode(invalid))
    }
}
