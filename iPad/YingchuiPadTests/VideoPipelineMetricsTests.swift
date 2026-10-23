import XCTest
import YingchuiProtocol
@testable import YingchuiPad

final class VideoPipelineMetricsTests: XCTestCase {
    func testSystemTimestampSeparatesArrivalGapFromApplicationDelay() {
        var metrics = PadReceivePipelineMetrics()
        metrics.systemReceive(at: 0, callbackAt: 10)
        metrics.systemReceive(at: 20, callbackAt: 10)
        XCTAssertEqual(metrics.systemToCallback.count, 0)
        metrics.systemReceive(at: 1_000_000_000, callbackAt: 1_001_000_000)
        metrics.systemReceive(at: 1_150_000_000, callbackAt: 1_152_000_000)
        XCTAssertEqual(metrics.systemPacketInterval.maximumNanoseconds, 150_000_000)
        XCTAssertEqual(metrics.systemToCallback.maximumNanoseconds, 2_000_000)
    }

    func testReportClearsWindowButPreservesPacketContinuity() throws {
        let stream = UUID()
        let fragment = VideoFragment(streamID: stream, frameID: 1, fragmentIndex: 0,
            fragmentCount: 1, presentationTimeMicroseconds: 0, isKeyFrame: true, payload: Data([1]))
        var metrics = PadReceivePipelineMetrics()
        metrics.packet(fragment, bytes: 100, now: 1_000_000_000)
        metrics.systemReceive(at: 1_000_000_000, callbackAt: 1_001_000_000)
        metrics.frame(1, now: 1_010_000_000)
        XCTAssertNil(metrics.report(streamID: stream, now: 2_000_000_000))
        let report = try XCTUnwrap(metrics.report(streamID: stream, now: 3_000_000_000))
        XCTAssertTrue(report.contains("收包 1，交付 1 帧"))
        XCTAssertEqual(metrics.packets, 0)
        XCTAssertEqual(metrics.assembly.count, 0)
        XCTAssertEqual(metrics.systemToCallback.count, 0)
        metrics.systemReceive(at: 3_000_000_000, callbackAt: 3_001_000_000)
        XCTAssertEqual(metrics.systemPacketInterval.maximumNanoseconds, 2_000_000_000)
        metrics = .init()
        XCTAssertEqual(metrics.systemPacketInterval.count, 0)
        XCTAssertNil(metrics.report(streamID: stream, now: 6_000_000_000))
    }
}
