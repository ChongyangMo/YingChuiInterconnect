import Testing
@testable import YingchuiProtocol

@Test func displayModeRoundTripAndReconfigurationIdentity() throws {
    for mode in [RemoteDisplayMode.mirror, .extended] {
        for placement in RemoteDisplayPlacement.allCases {
            let wire = WireMessage(kind: .streamStart, displayMode: mode, displayPlacement: placement)
            var decoder = WireMessageDecoder()
            #expect(try decoder.append(WireCodec.encode(wire)) == [wire])
        }
    }
    let dimensions = StreamDimensions(width: 2224, height: 1668)
    #expect(StreamRequest(quality: .native, viewport: dimensions, displayMode: .mirror) !=
            StreamRequest(quality: .native, viewport: dimensions, displayMode: .extended))
    #expect(StreamRequest(quality: .native, viewport: dimensions, displayPlacement: .left) !=
            StreamRequest(quality: .native, viewport: dimensions, displayPlacement: .right))
}

@Test func displayStateRequiresPlacementOnlyForExtension() {
    #expect(RemoteDisplayState(mode: .standalone).isValid)
    #expect(RemoteDisplayState(mode: .mirror).isValid)
    #expect(RemoteDisplayState(mode: .extended, placement: .left).isValid)
    #expect(!RemoteDisplayState(mode: .extended).isValid)
    #expect(!RemoteDisplayState(mode: .standalone, placement: .left).isValid)
}
