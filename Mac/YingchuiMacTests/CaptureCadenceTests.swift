import CoreMedia
import XCTest
@testable import YingchuiMac

final class CaptureCadenceTests: XCTestCase {
    func testMatchedDisplayCadenceDoesNotAddSecondThrottle() {
        for rate in [59.94, 60.0, 50.0] {
            XCTAssertEqual(MacCaptureCadencePolicy.minimumInterval(frameRate: 60, displayRefreshRate: rate), .zero)
        }
        XCTAssertEqual(MacCaptureCadencePolicy.minimumInterval(frameRate: 120, displayRefreshRate: 120), .zero)
    }

    func testFasterOrUnknownDisplayStillRespectsRequestedLimit() {
        for rate in [120.0, 0, -1, Double.nan, Double.infinity] {
            XCTAssertEqual(MacCaptureCadencePolicy.minimumInterval(frameRate: 60, displayRefreshRate: rate),
                CMTime(value: 1, timescale: 60))
        }
        XCTAssertEqual(MacCaptureCadencePolicy.minimumInterval(frameRate: 30, displayRefreshRate: 60),
            CMTime(value: 1, timescale: 30))
    }
}
