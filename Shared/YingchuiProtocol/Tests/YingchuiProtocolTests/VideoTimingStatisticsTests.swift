import XCTest
@testable import YingchuiProtocol

final class VideoTimingStatisticsTests: XCTestCase {
    func testEmptyAndInvalidClockSamplesAreNotReportedAsZeroLatency() {
        var metrics = VideoTimingStatistics()
        metrics.record(from: 20, to: 10)
        XCTAssertEqual(metrics.count, 0)
        XCTAssertEqual(metrics.summary, "无样本")
    }

    func testTimingWindowKeepsMeanPeakAndFrameBudgetCount() {
        var metrics = VideoTimingStatistics()
        metrics.record(10_000_000)
        metrics.record(50_000_000)
        XCTAssertEqual(metrics.count, 2)
        XCTAssertEqual(metrics.maximumNanoseconds, 50_000_000)
        XCTAssertTrue(metrics.summary.contains("均值 30.0/最大 50.0"))
        XCTAssertTrue(metrics.summary.contains("超33毫秒 1次"))
        metrics = .init()
        XCTAssertEqual(metrics.summary, "无样本")
    }
}
