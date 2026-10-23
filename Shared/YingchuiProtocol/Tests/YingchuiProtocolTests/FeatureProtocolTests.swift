import Foundation
import Testing
@testable import YingchuiProtocol

@Test func longInputPreservesEveryComposedCharacterAcrossMessages() throws {
    let original = String(repeating: "鹰e\u{301}👨‍👩‍👦", count: 200)
    let chunks = try RemoteTextPolicy.chunks(original)
    #expect(chunks.joined() == original)
    #expect(chunks.allSatisfy { !$0.isEmpty && $0.count <= 128 })
    for chunk in chunks {
        #expect(try RemoteControlValidator.command(from: WireMessage(kind: .textInput, text: chunk)) == .textInput(chunk))
    }
}

@Test func oversizedTextAndEmptyClipboardFailExplicitly() {
    #expect(throws: (any Error).self) { _ = try RemoteTextPolicy.chunks(String(repeating: "a", count: 4_097)) }
    #expect(throws: (any Error).self) { _ = try RemoteTextPolicy.validateClipboard(nil) }
    #expect(throws: (any Error).self) { _ = try RemoteTextPolicy.validateClipboard(String(repeating: "鹰", count: 22_000)) }
    #expect(throws: RemoteControlValidationError.textTooLong) {
        _ = try RemoteControlValidator.command(from: WireMessage(kind: .textInput, text: String(repeating: "a", count: 129)))
    }
}

@Test func audioPacketsRoundTripWithoutExceedingDatagramBudget() throws {
    let packet = AudioPacket(streamID: UUID(), sequence: .max, pcm: Data(repeating: 0xab, count: 960))
    let bytes = try AudioPacketCodec.encode(packet)
    #expect(bytes.count < 1_100)
    #expect(try AudioPacketCodec.decode(bytes) == packet)
    let key = VideoDatagramCrypto.makeKey()
    #expect(try AudioPacketCodec.decode(VideoDatagramCrypto.open(VideoDatagramCrypto.seal(bytes, key: key), key: key)) == packet)
}

@Test func audioRejectsTruncationLengthMismatchAndWrongMagic() throws {
    let packet = AudioPacket(streamID: UUID(), sequence: 1, pcm: Data(repeating: 0, count: 40))
    let data = try AudioPacketCodec.encode(packet)
    #expect(throws: (any Error).self) { _ = try AudioPacketCodec.decode(Data(data.dropLast())) }
    var wrong = data; wrong[0] = 0
    #expect(throws: (any Error).self) { _ = try AudioPacketCodec.decode(wrong) }
    #expect(throws: (any Error).self) { _ = try AudioPacketCodec.encode(AudioPacket(streamID: UUID(), sequence: 0, pcm: Data(count: 961))) }
}

@Test func clipboardAndAudioNegotiationSurviveWireRoundTrip() throws {
    let request = WireMessage(kind: .streamStart, audioPort: 12345, audioEnabled: true, videoPort: 12346)
    var decoder = WireMessageDecoder()
    #expect(try decoder.append(WireCodec.encode(request)) == [request])
    let result = WireMessage(kind: .clipboardResult, accepted: true, text: "跨设备文字")
    #expect(try decoder.append(WireCodec.encode(result)) == [result])
}
