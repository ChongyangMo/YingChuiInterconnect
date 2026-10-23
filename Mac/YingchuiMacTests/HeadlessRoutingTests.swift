import XCTest
@testable import YingchuiMac

final class HeadlessRoutingTests: XCTestCase {
    func testSystemPlaceholderIsRecognizedByHardwareIdentifiers() {
        XCTAssertTrue(MacDisplayRouting.isSystemVirtualDisplay(vendor: 1_970_170_734, model: 1_986_622_068))
        XCTAssertFalse(MacDisplayRouting.isSystemVirtualDisplay(vendor: 12_462, model: 3_879))
        XCTAssertFalse(MacDisplayRouting.isSystemVirtualDisplay(vendor: 0, model: 0))
        XCTAssertFalse(MacDisplayRouting.isSystemVirtualDisplay(vendor: 12_462, model: 0x76697274))
    }

    func testMacStreamDisplayIsRecognizedByHardwareIdentifiers() {
        XCTAssertTrue(MacDisplayRouting.isMacStreamDisplay(vendor: 0x4D53, model: 0x0001))
        XCTAssertFalse(MacDisplayRouting.isMacStreamDisplay(vendor: 0x5943, model: 0x4950))
        XCTAssertFalse(MacDisplayRouting.isMacStreamDisplay(vendor: 0x4D53, model: 0x0002))
        XCTAssertFalse(MacDisplayRouting.isMacStreamDisplay(vendor: 1_970_170_734, model: 1_986_622_068))
    }

    func testHeadlessReconnectIgnoresSelectedSystemPlaceholder() throws {
        XCTAssertNil(try MacDisplayRouting.mirrorTarget(selected: 152, online: [152],
            ownedVirtualDisplay: nil, systemVirtualDisplays: [152]))
        XCTAssertNil(try MacDisplayRouting.mirrorTarget(selected: nil, online: [152],
            ownedVirtualDisplay: nil, systemVirtualDisplays: [152]))
    }

    func testPlaceholderDoesNotHideRealDisplayOrReplaceInvalidSelection() throws {
        XCTAssertEqual(try MacDisplayRouting.mirrorTarget(selected: 1, online: [1, 152],
            ownedVirtualDisplay: nil, systemVirtualDisplays: [152]), 1)
        XCTAssertThrowsError(try MacDisplayRouting.mirrorTarget(selected: 152, online: [1, 152],
            ownedVirtualDisplay: nil, systemVirtualDisplays: [152]))
    }
}
