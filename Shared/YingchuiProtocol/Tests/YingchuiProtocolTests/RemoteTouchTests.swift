import Foundation
import Testing
@testable import YingchuiProtocol

@Test func touchCommandsRoundTripWithStreamAndGestureIdentity() throws {
    for phase in [RemoteTouchPhase.tap, .rightTap, .dragBegan, .dragMoved, .dragEnded, .scroll, .hover] {
        let touch = RemoteTouchInput(phase: phase, x: 0.25, y: 0.75,
            gestureID: phase.isDrag ? UUID() : nil, deltaX: phase == .scroll ? 12 : nil, deltaY: phase == .scroll ? -25 : nil)
        let message = WireMessage(kind: .touchInput, streamID: UUID(), touch: touch)
        var decoder = WireMessageDecoder()
        let decoded = try #require(decoder.append(WireCodec.encode(message)).first)
        #expect(decoded == message)
        #expect(try RemoteControlValidator.command(from: decoded) == .touchInput(touch))
    }
}

@Test func touchRejectsInvalidCoordinatesAndScrolling() {
    for value in [-0.001, 1.001, Double.nan, .infinity, -.infinity] {
        #expect(throws: RemoteControlValidationError.invalidCoordinate) {
            try RemoteTouchInput(phase: .tap, x: value, y: 0.5).validate()
        }
        #expect(throws: RemoteControlValidationError.invalidCoordinate) {
            try RemoteTouchInput(phase: .tap, x: 0.5, y: value).validate()
        }
    }
    #expect(throws: RemoteControlValidationError.invalidCoordinate) {
        try RemoteTouchInput(phase: .scroll, x: 0, y: 1, deltaX: 301, deltaY: 0).validate()
    }
}

@Test func touchRequiresMatchingPayloadShapeAndStream() {
    #expect(throws: RemoteControlValidationError.missingField) {
        try RemoteTouchInput(phase: .dragBegan, x: 0.5, y: 0.5).validate()
    }
    #expect(throws: RemoteControlValidationError.missingField) {
        try RemoteTouchInput(phase: .tap, x: 0.5, y: 0.5, gestureID: UUID()).validate()
    }
    #expect(throws: RemoteControlValidationError.missingField) {
        try RemoteControlInputMissingStream()
    }
}

private func RemoteControlInputMissingStream() throws {
    _ = try RemoteControlValidator.command(from: WireMessage(kind: .touchInput,
        touch: RemoteTouchInput(phase: .tap, x: 0.5, y: 0.5)))
}

@Test func scrollStagesRoundTripAndLegacyPayloadRemainsSupported() throws {
    for phase in [RemoteScrollPhase.began, .changed, .ended, .cancelled, .momentumBegan, .momentumChanged, .momentumEnded] {
        let input = RemoteTouchInput(phase: .scroll, x: 0.25, y: 0.5, deltaX: 0, deltaY: 1, scrollPhase: phase)
        try input.validate()
        let data = try JSONEncoder().encode(input)
        #expect(try JSONDecoder().decode(RemoteTouchInput.self, from: data) == input)
    }
    let legacy = Data(#"{"phase":"scroll","x":0.25,"y":0.5,"deltaX":0,"deltaY":1}"#.utf8)
    let input = try JSONDecoder().decode(RemoteTouchInput.self, from: legacy)
    try input.validate()
    #expect(input.scrollPhase == nil)
    #expect(throws: RemoteControlValidationError.unsupportedKind) {
        try RemoteTouchInput(phase: .tap, x: 0.25, y: 0.5, scrollPhase: .began).validate()
    }
}

@Test func touchCapabilityIsOptionalForExistingMouseClients() throws {
    let old = WireMessage(kind: .hello)
    let updated = WireMessage(kind: .hello, supportsTouch: true, supportsTouchHover: true)
    var decoder = WireMessageDecoder()
    let oldDecoded = try #require(decoder.append(WireCodec.encode(old)).first)
    #expect(oldDecoded.supportsTouch == nil)
    #expect(oldDecoded.supportsTouchHover == nil)
    let updatedDecoded = try #require(decoder.append(WireCodec.encode(updated)).first)
    #expect(updatedDecoded.supportsTouch == true)
    #expect(updatedDecoded.supportsTouchHover == true)
    #expect(try RemoteControlValidator.command(from: WireMessage(kind: .pointerMove, deltaX: 3, deltaY: -2))
            == .pointerMove(deltaX: 3, deltaY: -2))
}

@Test func touchHoverRejectsButtonGestureAndScrollPayloads() {
    #expect(throws: RemoteControlValidationError.missingField) {
        try RemoteTouchInput(phase: .hover, x: 0.5, y: 0.5, gestureID: UUID()).validate()
    }
    #expect(throws: RemoteControlValidationError.unsupportedKind) {
        try RemoteTouchInput(phase: .hover, x: 0.5, y: 0.5, deltaX: 0, deltaY: 0).validate()
    }
}
