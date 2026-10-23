import ApplicationServices
import Security
import XCTest
import YingchuiProtocol
@testable import YingchuiMac

final class MacInputMappingTests: XCTestCase {
    func testHostedAppDetectsTestRuntime() {
        XCTAssertNotNil(NSClassFromString("XCTestCase"))
    }

    func testTLSIdentityStoreRecognizesAuthorizationFailures() {
        let authorizationError = NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(errSecAuthFailed)
        )
        let wrappedError = NSError(
            domain: "MacInputMappingTests",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: authorizationError]
        )

        XCTAssertTrue(MacTLSIdentityStore.isAuthorizationFailure(authorizationError))
        XCTAssertTrue(MacTLSIdentityStore.isAuthorizationFailure(wrappedError))
        XCTAssertFalse(
            MacTLSIdentityStore.isAuthorizationFailure(
                NSError(domain: NSOSStatusErrorDomain, code: Int(errSecItemNotFound))
            )
        )
    }

    func testMouseButtonsMapToMatchingEvents() {
        XCTAssertEqual(MacInputMapping.mouseEventType(button: .left, pressed: true), .leftMouseDown)
        XCTAssertEqual(MacInputMapping.mouseEventType(button: .left, pressed: false), .leftMouseUp)
        XCTAssertEqual(MacInputMapping.mouseEventType(button: .right, pressed: true), .rightMouseDown)
        XCTAssertEqual(MacInputMapping.mouseEventType(button: .right, pressed: false), .rightMouseUp)
        XCTAssertNil(MacInputMapping.mouseEventType(button: .center, pressed: true))
    }

    func testRemoteKeysUseStableVirtualKeyCodes() {
        XCTAssertEqual(MacInputMapping.keyCode(for: .escape), 53)
        XCTAssertEqual(MacInputMapping.keyCode(for: .returnKey), 36)
        XCTAssertEqual(MacInputMapping.keyCode(for: .arrowUp), 126)
        XCTAssertEqual(MacInputMapping.keyCode(for: .letterA), 0)
        XCTAssertEqual(MacInputMapping.keyCode(for: .letterZ), 6)
    }

    func testScrollValuesRoundClampAndRejectNonFiniteInput() {
        XCTAssertEqual(MacInputMapping.clampedScrollValue(1.6), 2)
        XCTAssertEqual(MacInputMapping.clampedScrollValue(-1.6), -2)
        XCTAssertEqual(MacInputMapping.clampedScrollValue(Double(Int32.max) * 2), Int32.max)
        XCTAssertEqual(MacInputMapping.clampedScrollValue(Double(Int32.min) * 2), Int32.min)
        XCTAssertEqual(MacInputMapping.clampedScrollValue(.infinity), 0)
        XCTAssertEqual(MacInputMapping.clampedScrollValue(.nan), 0)
    }

    func testReleasingNoButtonsNeedsNoAccessibilityPermission() {
        XCTAssertTrue(MacInputController().releaseMouseButtons([]))
    }
}
