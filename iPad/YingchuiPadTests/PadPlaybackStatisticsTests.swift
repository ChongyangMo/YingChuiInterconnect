import AVFoundation
import SwiftUI
import XCTest
@testable import YingchuiPad
import YingchuiProtocol

final class PadPlaybackStatisticsTests: XCTestCase {
    func testThirteenInchViewportUsesNativePixels() {
        let dimensions = PadViewportSizing.pixelDimensions(
            pointSize: CGSize(width: 1_376, height: 1_032),
            nativeScale: 2
        )

        XCTAssertEqual(dimensions, StreamDimensions(width: 2_752, height: 2_064))
    }

    func testCommonIPadViewportsUseTheirNativeLandscapePixels() {
        let devices: [(name: String, points: CGSize, scale: CGFloat, pixels: StreamDimensions)] = [
            ("iPad Pro 13 英寸", CGSize(width: 1_376, height: 1_032), 2, StreamDimensions(width: 2_752, height: 2_064)),
            ("iPad Pro 12.9 英寸", CGSize(width: 1_366, height: 1_024), 2, StreamDimensions(width: 2_732, height: 2_048)),
            ("iPad Air 13 英寸", CGSize(width: 1_366, height: 1_024), 2, StreamDimensions(width: 2_732, height: 2_048)),
            ("iPad Pro 11 英寸新款", CGSize(width: 1_210, height: 834), 2, StreamDimensions(width: 2_420, height: 1_668)),
            ("iPad Pro 11 英寸旧款", CGSize(width: 1_194, height: 834), 2, StreamDimensions(width: 2_388, height: 1_668)),
            ("iPad Air 11 英寸", CGSize(width: 1_180, height: 820), 2, StreamDimensions(width: 2_360, height: 1_640)),
            ("iPad 第十代", CGSize(width: 1_180, height: 820), 2, StreamDimensions(width: 2_360, height: 1_640)),
            ("iPad Pro 10.5 英寸", CGSize(width: 1_112, height: 834), 2, StreamDimensions(width: 2_224, height: 1_668)),
            ("iPad 10.2 英寸", CGSize(width: 1_080, height: 810), 2, StreamDimensions(width: 2_160, height: 1_620)),
            ("iPad mini", CGSize(width: 1_133, height: 744), 2, StreamDimensions(width: 2_266, height: 1_488))
        ]

        for device in devices {
            let dimensions = PadViewportSizing.pixelDimensions(
                pointSize: device.points,
                nativeScale: device.scale
            )
            XCTAssertEqual(dimensions, device.pixels, device.name)
        }
    }

    func testPortraitViewportUsesTheSamePhysicalPixelsRotated() {
        let dimensions = PadViewportSizing.pixelDimensions(
            pointSize: CGSize(width: 1_032, height: 1_376),
            nativeScale: 2
        )

        XCTAssertEqual(dimensions, StreamDimensions(width: 2_064, height: 2_752))
    }

    func testEveryQualityKeepsTheFullScreenViewportOrientation() {
        let landscape = StreamDimensions(width: 2_420, height: 1_668)
        let portrait = StreamDimensions(width: 1_668, height: 2_420)

        for quality in StreamQualityPreset.allCases {
            let landscapeOutput = StreamRequest(quality: quality, viewport: landscape).dimensions
            let portraitOutput = StreamRequest(quality: quality, viewport: portrait).dimensions

            XCTAssertGreaterThan(landscapeOutput.width, landscapeOutput.height, quality.rawValue)
            XCTAssertGreaterThan(portraitOutput.height, portraitOutput.width, quality.rawValue)
            XCTAssertTrue(landscapeOutput.width.isMultiple(of: 2), quality.rawValue)
            XCTAssertTrue(landscapeOutput.height.isMultiple(of: 2), quality.rawValue)
            XCTAssertTrue(portraitOutput.width.isMultiple(of: 2), quality.rawValue)
            XCTAssertTrue(portraitOutput.height.isMultiple(of: 2), quality.rawValue)
        }
    }

    func testViewportSizingRejectsInvalidGeometry() {
        XCTAssertNil(
            PadViewportSizing.pixelDimensions(
                pointSize: CGSize(width: 0, height: 1_032),
                nativeScale: 2
            )
        )
        XCTAssertNil(
            PadViewportSizing.pixelDimensions(
                pointSize: CGSize(width: 1_376, height: CGFloat.infinity),
                nativeScale: 2
            )
        )
    }

    func testLatencyWindowKeepsNewestSamplesAndComputesPercentiles() {
        var window = LatencySampleWindow(capacity: 3)
        [40.0, 10.0, 30.0, 20.0].forEach { window.append($0) }

        XCTAssertEqual(window.values, [10, 30, 20])
        XCTAssertEqual(window.percentile(0.50), 20)
        XCTAssertEqual(window.percentile(0.95), 30)
    }

    func testLatencyWindowRejectsInvalidSamplesAndResets() {
        var window = LatencySampleWindow(capacity: 3)
        window.append(-1)
        window.append(.nan)
        window.append(.infinity)
        window.append(3.1)

        XCTAssertEqual(window.values, [3.1])
        window.reset()
        XCTAssertTrue(window.values.isEmpty)
        XCTAssertNil(window.percentile(0.95))
    }

    func testConcurrentCountersRemainExact() {
        let statistics = PadPlaybackStatistics()
        let queue = DispatchQueue(label: "PadPlaybackStatisticsTests", attributes: .concurrent)
        let group = DispatchGroup()

        for index in 0..<1_000 {
            group.enter()
            queue.async {
                statistics.recordDecodedFrame()
                if index.isMultiple(of: 4) {
                    statistics.recordDroppedFrame()
                }
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        let snapshot = statistics.snapshot()
        XCTAssertEqual(snapshot.decodedFrames, 1_000)
        XCTAssertEqual(snapshot.droppedFrames, 250)
    }

    func testResetClearsCounters() {
        let statistics = PadPlaybackStatistics()
        statistics.recordDecodedFrame()
        statistics.recordDroppedFrame()

        statistics.reset()

        let snapshot = statistics.snapshot()
        XCTAssertEqual(snapshot.decodedFrames, 0)
        XCTAssertEqual(snapshot.droppedFrames, 0)
    }

    @MainActor
    func testRendererRejectsMissingParameterSets() {
        let renderer = VideoRenderer()
        XCTAssertThrowsError(try renderer.configure(streamID: UUID(), parameterSets: []))
        XCTAssertThrowsError(try renderer.configure(streamID: UUID(), parameterSets: [Data([0])]))
    }

    @MainActor
    func testRendererConfiguresAttachedSurfaceWithoutOpaqueBars() {
        let renderer = VideoRenderer()
        let layer = AVSampleBufferDisplayLayer()

        renderer.attach(layer, videoGravity: .resizeAspect)

        XCTAssertEqual(layer.videoGravity, .resizeAspect)
        XCTAssertFalse(layer.isOpaque)
        XCTAssertEqual(layer.backgroundColor, UIColor.clear.cgColor)
        renderer.detach(layer)
    }

    @MainActor
    func testFullScreenVideoSurfaceExtendsThroughSafeArea() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first(where: { $0.activationState == .foregroundActive }),
            "等待前台窗口超时，请确认 iPad 已解锁且测试应用位于前台"
        )
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let renderer = VideoRenderer()
        var reportedViewport = CGSize.zero
        let controller = UIHostingController(
            rootView: FullScreenVideoSurface(renderer: renderer) { size in
                reportedViewport = size
            }.ignoresSafeArea(.container)
        )
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }

        try await Task.sleep(for: .milliseconds(100))
        controller.view.layoutIfNeeded()

        let surface = try XCTUnwrap(firstSampleBufferView(in: controller.view))
        let surfaceFrame = surface.convert(surface.bounds, to: window)
        XCTAssertEqual(surfaceFrame.minX, window.bounds.minX, accuracy: 0.5)
        XCTAssertEqual(surfaceFrame.minY, window.bounds.minY, accuracy: 0.5)
        XCTAssertEqual(surfaceFrame.maxX, window.bounds.maxX, accuracy: 0.5)
        XCTAssertEqual(surfaceFrame.maxY, window.bounds.maxY, accuracy: 0.5)
        XCTAssertEqual(surface.sampleBufferLayer.videoGravity, .resizeAspect)
        XCTAssertEqual(reportedViewport.width, window.bounds.width, accuracy: 0.5)
        XCTAssertEqual(reportedViewport.height, window.bounds.height, accuracy: 0.5)
    }

    @MainActor
    private func firstSampleBufferView(in view: UIView) -> SampleBufferView? {
        if let surface = view as? SampleBufferView {
            return surface
        }
        for subview in view.subviews {
            if let surface = firstSampleBufferView(in: subview) {
                return surface
            }
        }
        return nil
    }
}
