import Combine
import XCTest
@testable import YingchuiPad
import YingchuiProtocol

final class PadKeyboardLanguageTests: XCTestCase {
    @MainActor
    func testLanguageChangesOnlyAfterMatchingAcknowledgement() async throws {
        let model = PadConnectionModel()
        let id = UUID()
        model.keyboardLanguageChanging = true
        model.networkQueue.sync {
            model.pendingKeyboardLanguageRequest = id
            model.requestedKeyboardLanguage = .pinyin
            _ = model.controlAcknowledgements.begin(id: id, at: DispatchTime.now().uptimeNanoseconds)
        }
        XCTAssertEqual(model.remoteKeyboardLanguage, .english)
        let changed = expectation(description: "输入法确认")
        let subscription = model.$remoteKeyboardLanguage.filter { $0 == .pinyin }.sink { _ in changed.fulfill() }
        defer { subscription.cancel() }
        model.networkQueue.async {
            model.handleControlAcknowledgement(WireMessage(id: id, kind: .controlAck, keyboardLanguage: .pinyin))
        }
        await fulfillment(of: [changed], timeout: 3)
        XCTAssertFalse(model.keyboardLanguageChanging)
    }

    @MainActor
    func testInvalidLanguageAcknowledgementDoesNotPretendToSwitch() async throws {
        let model = PadConnectionModel()
        model.keyboardLanguageChanging = true
        let reported = expectation(description: "输入法错误已报告")
        let subscription = model.$transferStatus.filter { $0 == "Mac 输入法切换回执无效" }.sink { _ in reported.fulfill() }
        defer { subscription.cancel() }
        model.networkQueue.async {
            model.pendingKeyboardLanguageRequest = UUID()
            model.requestedKeyboardLanguage = .pinyin
            model.finishKeyboardLanguageChange(language: .english)
        }
        await fulfillment(of: [reported], timeout: 3)
        XCTAssertFalse(model.keyboardLanguageChanging)
        XCTAssertEqual(model.remoteKeyboardLanguage, .english)
    }
}
