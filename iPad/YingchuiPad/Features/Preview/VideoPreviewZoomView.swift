import UIKit
import YingchuiProtocol

/// 缩放只改变预览显示层，既不改变编码视口，也不重新建立视频链路。
final class VideoPreviewZoomView: UIView, UIScrollViewDelegate {
    let scrollView = UIScrollView()
    let content = UIView()
    let video = SampleBufferView()
    let touch = DirectTouchView()
    let resetButton = UIButton(type: .system)
    private var viewportSize = CGSize.zero
    private var streamID: UUID?
    private var aspectRatio: Double?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .black
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.delaysContentTouches = false
        scrollView.bounces = false
        scrollView.bouncesZoom = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
        scrollView.panGestureRecognizer.maximumNumberOfTouches = 2
        scrollView.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scrollView.pinchGestureRecognizer?.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scrollView.accessibilityIdentifier = "video-preview-zoom"
        addSubview(scrollView)
        scrollView.addSubview(content)
        content.addSubview(video)
        content.addSubview(touch)
        touch.previewNavigation = true
        video.isAccessibilityElement = true
        video.accessibilityLabel = "Mac 预览画面"
        video.accessibilityHint = "双指捏合缩放，双指移动查看画面"
        installResetButton()
        let actions = [
            UIAccessibilityCustomAction(name: "放大预览", target: self, selector: #selector(enlarge)),
            UIAccessibilityCustomAction(name: "缩小预览", target: self, selector: #selector(shrink)),
            UIAccessibilityCustomAction(name: "还原预览大小", target: self, selector: #selector(resetAccessible))
        ]
        video.accessibilityCustomActions = actions
        touch.accessibilityCustomActions = actions
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不支持从编码器创建可缩放预览") }

    func configure(aspectRatio: Double?, streamID: UUID?, touchEnabled: Bool,
                   onSend: @escaping (RemoteTouchInput) -> Void) {
        if self.streamID != streamID || self.aspectRatio != aspectRatio {
            resetZoom(animated: false)
            self.streamID = streamID
            self.aspectRatio = aspectRatio
        }
        touch.configure(aspectRatio: aspectRatio, streamID: streamID, enabled: touchEnabled, onSend: onSend)
        video.isAccessibilityElement = !touchEnabled
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        if viewportSize != bounds.size {
            touch.cancelInteraction()
            scrollView.setZoomScale(1, animated: false)
            viewportSize = bounds.size
            content.frame = CGRect(origin: .zero, size: bounds.size)
            video.frame = content.bounds
            touch.frame = content.bounds
            scrollView.contentSize = bounds.size
            scrollView.contentOffset = .zero
            updateZoomControls()
        }
        resetButton.frame = CGRect(x: max(0, bounds.width - 52), y: 8, width: 44, height: 44)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        touch.cancelInteraction()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        touch.cancelInteraction()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { updateZoomControls() }

    func resetZoom(animated: Bool) {
        touch.cancelInteraction()
        scrollView.setZoomScale(1, animated: animated && !UIAccessibility.isReduceMotionEnabled)
        if !animated || UIAccessibility.isReduceMotionEnabled { scrollView.contentOffset = .zero }
        updateZoomControls()
    }

    private func installResetButton() {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "arrow.counterclockwise")
        configuration.baseForegroundColor = .white
        configuration.background.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        configuration.background.cornerRadius = 22
        resetButton.configuration = configuration
        resetButton.accessibilityLabel = "还原预览大小"
        resetButton.accessibilityIdentifier = "video-preview-reset"
        resetButton.addTarget(self, action: #selector(resetPressed), for: .touchUpInside)
        resetButton.isHidden = true
        addSubview(resetButton)
    }

    private func updateZoomControls() {
        resetButton.isHidden = scrollView.zoomScale <= 1.001
        let value = "\(Int((scrollView.zoomScale * 100).rounded()))%"
        video.accessibilityValue = value
        touch.accessibilityValue = value
    }

    @objc private func resetPressed() { resetZoom(animated: true) }
    @objc private func resetAccessible() -> Bool { resetZoom(animated: true); return true }
    @objc private func enlarge() -> Bool { changeZoom(by: 1.5); return true }
    @objc private func shrink() -> Bool { changeZoom(by: 1 / 1.5); return true }
    private func changeZoom(by factor: CGFloat) {
        touch.cancelInteraction()
        scrollView.setZoomScale(min(4, max(1, scrollView.zoomScale * factor)), animated: !UIAccessibility.isReduceMotionEnabled)
    }
}
