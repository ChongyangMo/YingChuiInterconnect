import UIKit
import XCTest
import YingchuiProtocol
@testable import YingchuiPad

@MainActor
final class VideoPreviewZoomTests: XCTestCase {
    private func makeView(size: CGSize = CGSize(width: 800, height: 600),
                          streamID: UUID = UUID(), onSend: @escaping (RemoteTouchInput) -> Void = { _ in }) -> VideoPreviewZoomView {
        let view = VideoPreviewZoomView(frame: CGRect(origin: .zero, size: size))
        view.configure(aspectRatio: 4.0 / 3, streamID: streamID, touchEnabled: true, onSend: onSend)
        view.layoutIfNeeded()
        view.touch.layoutIfNeeded()
        return view
    }

    func testZoomAndPanKeepRemoteTapAlignedWithDisplayedPixel() throws {
        var events: [RemoteTouchInput] = []
        let view = makeView { events.append($0) }
        view.scrollView.setZoomScale(2, animated: false)
        view.scrollView.contentOffset = CGPoint(x: 200, y: 150)
        view.layoutIfNeeded()
        // 预览中心映射到未缩放画面的 (300,225)，即原图 37.5%。
        let location = view.touch.convert(CGPoint(x: 400, y: 300), from: view)
        XCTAssertEqual(location.x, 300, accuracy: 0.01)
        XCTAssertEqual(location.y, 225, accuracy: 0.01)
        view.touch.interaction.tap(at: location)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.x, 0.375, accuracy: 0.001)
        XCTAssertEqual(event.y, 0.375, accuracy: 0.001)
        XCTAssertEqual(view.video.bounds.size, CGSize(width: 800, height: 600))
        XCTAssertFalse(view.resetButton.isHidden)
    }

    func testTwoFingerNavigationEndsDragWithoutSendingRemoteScroll() {
        var events: [RemoteTouchInput] = []
        let view = makeView { events.append($0) }
        view.touch.interaction.beginDrag(at: CGPoint(x: 100, y: 100))
        view.scrollViewWillBeginZooming(view.scrollView, with: view.content)
        view.scrollViewWillBeginDragging(view.scrollView)
        XCTAssertEqual(events.map(\.phase), [.dragBegan, .dragEnded])
        let remoteScroll = view.touch.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }
            .first { $0.minimumNumberOfTouches == 2 }
        XCTAssertEqual(remoteScroll?.isEnabled, false)
        XCTAssertEqual(view.scrollView.panGestureRecognizer.minimumNumberOfTouches, 2)
        XCTAssertEqual(view.scrollView.panGestureRecognizer.maximumNumberOfTouches, 2)
        XCTAssertFalse(view.scrollView.delaysContentTouches)
        let fullScreen = DirectTouchView()
        XCTAssertEqual(fullScreen.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }
            .first { $0.minimumNumberOfTouches == 2 }?.isEnabled, true)
    }

    func testResetRestoresWholePictureAndHidesButton() {
        let view = makeView()
        view.scrollView.setZoomScale(4, animated: false)
        view.scrollView.contentOffset = CGPoint(x: 1000, y: 700)
        XCTAssertFalse(view.resetButton.isHidden)
        view.resetZoom(animated: false)
        XCTAssertEqual(view.scrollView.zoomScale, 1)
        XCTAssertEqual(view.scrollView.contentOffset, .zero)
        XCTAssertTrue(view.resetButton.isHidden)
        XCTAssertEqual(view.resetButton.frame.size, CGSize(width: 44, height: 44))
    }

    func testModelUpdatesPreserveZoomButNewStreamResetsIt() {
        let id = UUID()
        let view = makeView(streamID: id)
        view.scrollView.setZoomScale(2, animated: false)
        view.configure(aspectRatio: 4.0 / 3, streamID: id, touchEnabled: true) { _ in }
        XCTAssertEqual(view.scrollView.zoomScale, 2)
        view.configure(aspectRatio: 4.0 / 3, streamID: UUID(), touchEnabled: true) { _ in }
        XCTAssertEqual(view.scrollView.zoomScale, 1)
        XCTAssertEqual(view.scrollView.contentOffset, .zero)
    }

    func testRotationAndWindowResizeRestoreValidGeometry() {
        let view = makeView()
        for size in [CGSize(width: 375, height: 280), CGSize(width: 1112, height: 834), CGSize(width: 600, height: 800)] {
            view.scrollView.setZoomScale(3, animated: false)
            view.frame.size = size
            view.setNeedsLayout()
            view.layoutIfNeeded()
            XCTAssertEqual(view.scrollView.zoomScale, 1)
            XCTAssertEqual(view.video.bounds.size, size)
            XCTAssertEqual(view.scrollView.contentSize, size)
            XCTAssertEqual(view.scrollView.contentOffset, .zero)
        }
    }

    func testMouseModeKeepsLocalZoomWithoutRemoteTouchAndProvidesAccessibleActions() {
        let view = makeView()
        view.configure(aspectRatio: 4.0 / 3, streamID: UUID(), touchEnabled: false) { _ in XCTFail("鼠标模式预览不得发送触摸") }
        XCTAssertFalse(view.touch.isUserInteractionEnabled)
        XCTAssertTrue(view.video.isAccessibilityElement)
        XCTAssertEqual(view.video.accessibilityCustomActions?.count, 3)
        XCTAssertEqual(view.touch.accessibilityCustomActions?.count, 3)
        view.scrollView.setZoomScale(2, animated: false)
        XCTAssertEqual(view.video.accessibilityValue, "200%")
        XCTAssertFalse(view.resetButton.isHidden)
    }
}
