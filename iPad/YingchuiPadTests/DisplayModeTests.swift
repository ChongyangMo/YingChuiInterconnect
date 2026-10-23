import Combine
import XCTest
import YingchuiProtocol
@testable import YingchuiPad

final class DisplayModeTests: XCTestCase {
    @MainActor
    func testOnlyCurrentStreamMayUpdateDisplayState() async {
        let model = PadConnectionModel(startServices: false)
        let request = UUID(), stream = UUID()
        model.wantsStreaming = true
        model.videoRequestID.set(request)
        model.activeStreamID = stream
        model.activeDisplayState = RemoteDisplayState(mode: .mirror)
        model.handleDisplayState(WireMessage(id: UUID(), kind: .displayState, streamID: stream,
            displayState: RemoteDisplayState(mode: .standalone)))
        model.handleDisplayState(WireMessage(id: request, kind: .displayState, streamID: UUID(),
            displayState: RemoteDisplayState(mode: .standalone)))
        await Task.yield()
        XCTAssertEqual(model.activeDisplayState?.mode, .mirror)
        let updated = expectation(description: "真实显示模式回执")
        let subscription = model.$activeDisplayState.filter { $0?.mode == .extended }.sink { _ in updated.fulfill() }
        model.handleDisplayState(WireMessage(id: request, kind: .displayState, streamID: stream,
            displayState: RemoteDisplayState(mode: .extended, placement: .left)))
        await fulfillment(of: [updated], timeout: 3)
        subscription.cancel()
        XCTAssertEqual(model.activeDisplayState?.placement, .left)
        model.stopStreaming()
    }

    @MainActor
    func testModeChangeWaitsForConfirmationAndParticipatesInStreamRequest() {
        let saved = UserDefaults.standard.object(forKey: "YingchuiDisplayMode")
        defer { UserDefaults.standard.set(saved, forKey: "YingchuiDisplayMode") }
        let model = PadConnectionModel(startServices: false)
        model.selectedDisplayMode = .mirror
        model.isStreaming = true
        model.wantsStreaming = true
        model.activeDisplayState = RemoteDisplayState(mode: .mirror)
        model.selectDisplayMode(.extended)
        XCTAssertEqual(model.streamRequest.displayMode, .extended)
        XCTAssertEqual(model.activeDisplayState?.mode, .mirror)
        XCTAssertTrue(model.displayModeChanging)
        XCTAssertEqual(model.displayModeTitle, "正在切换")
        model.selectDisplayMode(.standalone)
        XCTAssertEqual(model.selectedDisplayMode, .extended)
        model.stopStreaming()
        XCTAssertNil(model.activeDisplayState)
        XCTAssertFalse(model.displayModeChanging)
    }

    @MainActor
    func testMalformedDisplayStateStopsStreamInsteadOfReportingSuccess() async {
        let model = PadConnectionModel(startServices: false)
        let request = UUID(), stream = UUID()
        model.wantsStreaming = true
        model.isStreaming = true
        model.videoRequestID.set(request)
        model.activeStreamID = stream
        model.handleDisplayState(WireMessage(id: request, kind: .displayState, streamID: stream,
            displayState: RemoteDisplayState(mode: .extended)))
        XCTAssertFalse(model.wantsStreaming)
        XCTAssertNil(model.activeStreamID)
    }
}
