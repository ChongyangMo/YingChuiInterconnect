import SwiftUI
import UIKit
import YingchuiProtocol

struct DirectTouchSurface: UIViewRepresentable {
    let aspectRatio: Double?
    let streamID: UUID?
    let enabled: Bool
    let onSend: (RemoteTouchInput) -> Void

    func makeUIView(context: Context) -> DirectTouchView { DirectTouchView() }
    func updateUIView(_ view: DirectTouchView, context: Context) {
        view.configure(aspectRatio: aspectRatio, streamID: streamID, enabled: enabled, onSend: onSend)
    }
    static func dismantleUIView(_ view: DirectTouchView, coordinator: Void) { view.cancelInteraction() }
}

final class DirectTouchView: UIView, UIGestureRecognizerDelegate {
    let interaction = DirectTouchInteraction()
    private var streamID: UUID?
    private var dragSuppressed = false
    private var scrollAnchor: CGPoint?
    private var fingerScrollSuppressed = false
    private var scrollTicker: DirectTouchScrollTicker?
    private weak var latestTouch: UITouch?
    private var suppressBrakingTap = false
    // 预览中的双指手势交给父级缩放容器；全屏仍保留远程滚动。
    var previewNavigation = false {
        didSet {
            for recognizer in gestureRecognizers ?? [] {
                if let pan = recognizer as? UIPanGestureRecognizer, pan.minimumNumberOfTouches == 2 {
                    pan.isEnabled = !previewNavigation
                }
            }
            accessibilityHint = previewNavigation
                ? "点按点击，单指滑动滚动，长按悬停或移动拖拽，双指轻点右键，双指缩放或移动预览"
                : "点按或双击，单指滑动滚动，长按悬停或移动拖拽，双指轻点右键"
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        isAccessibilityElement = true
        accessibilityLabel = "远程触摸屏"
        accessibilityHint = "点按或双击，单指滑动滚动，长按悬停或移动拖拽，双指轻点右键"
        installRecognizers()
        scrollTicker = DirectTouchScrollTicker(session: interaction.fingerScroll)
        NotificationCenter.default.addObserver(self, selector: #selector(cancelInteraction),
            name: UIApplication.willResignActiveNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不支持从编码器创建触摸控制视图") }

    func configure(aspectRatio: Double?, streamID: UUID?, enabled: Bool, onSend: @escaping (RemoteTouchInput) -> Void) {
        if self.streamID != streamID || interaction.aspectRatio != aspectRatio || !enabled { cancelInteraction() }
        self.streamID = streamID
        interaction.aspectRatio = aspectRatio
        interaction.onSend = onSend
        isUserInteractionEnabled = enabled
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if interaction.size != bounds.size { cancelInteraction(); interaction.size = bounds.size }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelInteraction() }
    }

    private func installRecognizers() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let rightTap = UITapGestureRecognizer(target: self, action: #selector(rightTapped(_:)))
        rightTap.numberOfTouchesRequired = 2
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.45
        hold.allowableMovement = 8
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        drag.maximumNumberOfTouches = 1
        drag.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        let fingerScroll = UIPanGestureRecognizer(target: self, action: #selector(fingerScrolled(_:)))
        fingerScroll.maximumNumberOfTouches = 1
        fingerScroll.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        for gesture in [tap, hold] {
            gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                         NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        }
        for gesture in [rightTap, scroll] {
            gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        }
        for gesture in [tap, rightTap, hold, drag, fingerScroll, scroll] {
            gesture.delegate = self
            addGestureRecognizer(gesture)
        }
        tap.require(toFail: hold)
        tap.require(toFail: rightTap)
        drag.require(toFail: hold)
        fingerScroll.require(toFail: hold)
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        if recognizer.state == .ended, !suppressBrakingTap { interaction.tap(at: recognizer.location(in: self)) }
    }
    @objc private func rightTapped(_ recognizer: UITapGestureRecognizer) {
        if recognizer.state == .ended { interaction.tap(at: recognizer.location(in: self), right: true) }
    }
    @objc private func held(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            interaction.beginHold(at: recognizer.location(in: self))
        case .changed:
            if recognizer.numberOfTouches == 1 {
                interaction.moveHold(to: recognizer.location(in: self))
            } else {
                interaction.endHold()
            }
        case .ended:
            interaction.endHold(at: recognizer.location(in: self))
        case .cancelled, .failed:
            interaction.endHold()
        default: break
        }
    }
    @objc private func dragged(_ recognizer: UIPanGestureRecognizer) {
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            dragSuppressed = false
            let translation = recognizer.translation(in: self)
            interaction.beginDrag(at: CGPoint(x: point.x - translation.x, y: point.y - translation.y))
            interaction.moveDrag(to: point)
        case .changed:
            if recognizer.numberOfTouches > 1 { interaction.endDrag(); dragSuppressed = true }
            if !dragSuppressed { interaction.moveDrag(to: point) }
        case .ended:
            interaction.endDrag(at: point)
        case .cancelled, .failed:
            interaction.endDrag()
        default: break
        }
    }
    @objc private func fingerScrolled(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            fingerScrollSuppressed = false
            let point = recognizer.location(in: self)
            let translation = recognizer.translation(in: self)
            interaction.beginFingerScroll(at: CGPoint(x: point.x - translation.x, y: point.y - translation.y))
        case .changed:
            if recognizer.numberOfTouches != 1 {
                interaction.cancelFingerScroll()
                fingerScrollSuppressed = true
            }
        case .ended:
            interaction.moveFingerScroll(by: recognizer.translation(in: self))
            interaction.fingerScroll.end(velocity: recognizer.velocity(in: self),
                                         allowsMomentum: !UIAccessibility.isReduceMotionEnabled)
            fingerScrollSuppressed = true
            return
        case .cancelled, .failed:
            interaction.cancelFingerScroll()
            fingerScrollSuppressed = true
            return
        default: return
        }
        if !fingerScrollSuppressed { interaction.moveFingerScroll(by: recognizer.translation(in: self)) }
        recognizer.setTranslation(.zero, in: self)
    }
    @objc private func scrolled(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            interaction.cancelFingerScroll()
            fingerScrollSuppressed = true
            interaction.endHold()
            interaction.endHover()
            scrollAnchor = recognizer.location(in: self)
            dragSuppressed = true
        case .changed: break
        case .ended, .cancelled, .failed:
            scrollAnchor = nil
            return
        default: return
        }
        guard let scrollAnchor else { return }
        interaction.scroll(at: scrollAnchor, translation: recognizer.translation(in: self))
        recognizer.setTranslation(.zero, in: self)
    }
    @objc func cancelInteraction() {
        scrollAnchor = nil
        fingerScrollSuppressed = true
        interaction.cancelFingerScroll()
        dragSuppressed = true
        interaction.endHold()
        interaction.endHover()
        interaction.endDrag()
        // 同时取消尚未达到长按时间的手势，旧触点不能在新画面上重新按下。
        for gesture in gestureRecognizers ?? [] where gesture.isEnabled {
            gesture.isEnabled = false
            gesture.isEnabled = true
        }
    }


    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        if latestTouch !== touch {
            latestTouch = touch
            suppressBrakingTap = interaction.fingerScroll.isDecelerating
            if suppressBrakingTap { interaction.cancelFingerScroll() }
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if previewNavigation, gestureRecognizer is UIPanGestureRecognizer,
           let owner = other.view as? UIScrollView, isDescendant(of: owner),
           other === owner.pinchGestureRecognizer || other === owner.panGestureRecognizer {
            return true
        }
        return gestureRecognizer is UIPanGestureRecognizer && other is UIPanGestureRecognizer
            && gestureRecognizer.view === self && other.view === self
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let location = gestureRecognizer.location(in: self)
        return DirectTouchGeometry.point(location, in: bounds.size, aspectRatio: interaction.aspectRatio) != nil
    }
}
