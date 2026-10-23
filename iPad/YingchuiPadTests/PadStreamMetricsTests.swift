import SwiftUI
import XCTest
@testable import YingchuiPad

final class PadStreamMetricsTests: XCTestCase {
    @MainActor
    func testFrameRateUsesElapsedTimeAndReportsZeroWhenStopped() throws {
        let metrics = PadStreamMetrics(), stream = UUID()
        metrics.configure(streamID: stream, width: 2224, height: 1668, decodedFrames: 100, now: 0)
        XCTAssertNil(metrics.framesPerSecond)
        XCTAssertEqual(metrics.resolution, "2224×1668")
        metrics.sample(streamID: stream, decodedFrames: 190, audioMilliseconds: 115, now: 1_500_000_000)
        XCTAssertEqual(try XCTUnwrap(metrics.framesPerSecond), 60, accuracy: 0.001)
        metrics.sample(streamID: stream, decodedFrames: 190, audioMilliseconds: nil, now: 2_500_000_000)
        XCTAssertEqual(metrics.framesPerSecond, 0)
        XCTAssertNil(metrics.audioMilliseconds)
    }

    @MainActor
    func testReconfigurationAndOutOfOrderSamplesCannotReuseOldFrameRate() throws {
        let metrics = PadStreamMetrics(), first = UUID(), next = UUID()
        metrics.configure(streamID: first, width: 2224, height: 1668, decodedFrames: 100, now: 0)
        metrics.sample(streamID: first, decodedFrames: 160, audioMilliseconds: 100, now: 1_000_000_000)
        metrics.configure(streamID: next, width: 1920, height: 1080, decodedFrames: 160, now: 1_000_000_000)
        metrics.sample(streamID: first, decodedFrames: 220, audioMilliseconds: 100, now: 2_000_000_000)
        XCTAssertNil(metrics.framesPerSecond)
        metrics.sample(streamID: next, decodedFrames: 220, audioMilliseconds: 100, now: 2_000_000_000)
        metrics.sample(streamID: next, decodedFrames: 300, audioMilliseconds: 100, now: 1_500_000_000)
        XCTAssertEqual(metrics.framesPerSecond, 60)
        metrics.sample(streamID: next, decodedFrames: 5, audioMilliseconds: 100, now: 3_000_000_000)
        XCTAssertNil(metrics.framesPerSecond)
        metrics.sample(streamID: next, decodedFrames: 65, audioMilliseconds: 100, now: 4_000_000_000)
        XCTAssertEqual(metrics.framesPerSecond, 60)
        XCTAssertEqual(metrics.resolution, "1920×1080")
    }

    @MainActor
    func testInvalidAndStaleLatencyNeverLooksLikeLiveData() {
        let metrics = PadStreamMetrics(), stream = UUID()
        metrics.configure(streamID: stream, width: 0, height: 0, decodedFrames: 0, now: 0)
        XCTAssertNil(metrics.resolution)
        for invalid in [Double.nan, .infinity, -1] {
            metrics.recordRoundTrip(invalid, now: 0)
            metrics.sample(streamID: stream, decodedFrames: 1, audioMilliseconds: invalid, now: 1)
            XCTAssertNil(metrics.roundTripMilliseconds)
            XCTAssertNil(metrics.audioMilliseconds)
        }
        metrics.recordRoundTrip(24, now: 1_000_000_000)
        XCTAssertEqual(metrics.roundTripMilliseconds, 24, "往返延迟不能擅自除以二")
        XCTAssertTrue(metrics.isFresh(metrics.pingAt, now: 3_999_999_999))
        XCTAssertFalse(metrics.isFresh(metrics.pingAt, now: 4_000_000_000))
        XCTAssertFalse(metrics.isFresh(metrics.pingAt, now: 0))
        metrics.reset()
        XCTAssertNil(metrics.pingAt)
        XCTAssertNil(metrics.roundTripMilliseconds)
        XCTAssertNil(metrics.updatedAt)
        XCTAssertNil(metrics.resolution)
    }

    @MainActor
    func testStatisticsCallbackFeedsActualDecodedCountAndStopClearsMetrics() {
        let model = PadConnectionModel(startServices: false), stream = UUID(), generation = UUID()
        model.wantsStreaming = true
        model.isStreaming = true
        model.activeStreamID = stream
        model.videoReceiverGeneration.set(generation)
        model.streamMetrics.configure(streamID: stream, width: 2224, height: 1668, decodedFrames: 0, now: 0)
        for _ in 0..<60 { model.playbackStatistics.recordDecodedFrame() }
        model.handleVideoStatistics(PadVideoReceiveSnapshot(generation: generation, streamID: stream,
            uptimeNanoseconds: 1_000_000_000, packets: 200, assembled: 70, dropped: 0), now: 1_000_000_000)
        XCTAssertEqual(model.streamMetrics.framesPerSecond, 60, "不能用收包数或组帧数冒充解码数")
        model.stopStreaming()
        XCTAssertNil(model.streamMetrics.framesPerSecond)
        XCTAssertNil(model.streamMetrics.resolution)
    }

    @MainActor
    func testVisibilityMenuDefaultsOnAndPersistsUserChoice() throws {
        let name = "MetricsTests.\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        let builder = PadMoreMenuItems(model: PadConnectionModel(startServices: false), showKeyboard: {},
            exitFullScreen: nil, exportDiagnostics: { _ in }, preferences: preferences)
        let action = try XCTUnwrap(builder.makeItems().compactMap { $0 as? UIAction }.first { $0.title == "显示回传信息" })
        XCTAssertEqual(action.state, .on)
        let button = UIButton()
        button.addAction(action, for: .primaryActionTriggered)
        button.sendActions(for: .primaryActionTriggered)
        XCTAssertFalse(preferences.bool(forKey: PadStreamMetrics.visibilityKey))
        XCTAssertEqual((builder.makeItems().first { $0.title == "显示回传信息" } as? UIAction)?.state, .off)
    }

    @MainActor
    func testCompactMetricLayouts() throws {
        let metrics = PadStreamMetrics(), stream = UUID()
        let now = DispatchTime.now().uptimeNanoseconds
        metrics.configure(streamID: stream, width: 2224, height: 1668, decodedFrames: 0, now: now - 1_000_000_000)
        metrics.sample(streamID: stream, decodedFrames: 60, audioMilliseconds: 135, now: now)
        metrics.recordRoundTrip(28, now: now)
        let name = "MetricsRender.\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        for width: CGFloat in [320, 1000] {
            let view = PadStreamMetricsView(metrics: metrics)
                .defaultAppStorage(preferences)
                .frame(width: width, height: 90)
                .background(Color.white)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            let attachment = XCTAttachment(image: image)
            attachment.name = "回传信息-\(Int(width))"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
