import XCTest
@testable import YingchuiPad

final class PresentationAgeTests: XCTestCase {
    func testBurstDiscardsOnlyExpiredDecodedPicturesAndRetainsNewest() {
        XCTAssertEqual(PadPresentationAgePolicy.discardCount(enqueuedAt: [0, 16_000_000, 32_000_000],
            now: 45_000_000, refreshInterval: 16_666_667), 1)
        XCTAssertEqual(PadPresentationAgePolicy.discardCount(enqueuedAt: [0, 1, 2],
            now: 1_000_000_000, refreshInterval: 16_666_667), 2)
        XCTAssertEqual(PadPresentationAgePolicy.discardCount(enqueuedAt: [0],
            now: 1_000_000_000, refreshInterval: 16_666_667), 0)
    }

    func testNormalCadenceKeepsToleranceAndAdaptsToRefreshPeriod() {
        let times: [UInt64] = [0, 10_000_000]
        XCTAssertEqual(PadPresentationAgePolicy.discardCount(enqueuedAt: times,
            now: 35_333_334, refreshInterval: 16_666_667), 0)
        XCTAssertEqual(PadPresentationAgePolicy.discardCount(enqueuedAt: times,
            now: 35_333_335, refreshInterval: 16_666_667), 1)
        XCTAssertEqual(PadPresentationAgePolicy.discardCount(enqueuedAt: times,
            now: 20_000_000, refreshInterval: 8_333_334), 1)
    }

    func testEmptyAndFutureTimestampsDoNotDiscardPictures() {
        XCTAssertEqual(PadPresentationAgePolicy.discardCount(enqueuedAt: [], now: 1, refreshInterval: 1), 0)
        XCTAssertEqual(PadPresentationAgePolicy.discardCount(enqueuedAt: [100, 110], now: 90, refreshInterval: 1), 0)
    }
}
