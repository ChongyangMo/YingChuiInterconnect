import SwiftUI
import UIKit

struct RemoteGestureSurface: UIViewRepresentable {
    var streamID: UUID? = nil
    var enabled = true
    let onMove: (Double, Double) -> Void
    let onTap: () -> Void
    let onRightTap: () -> Void
    let onScroll: (Double, Double) -> Void
    let onDragChanged: (Bool) -> Void

    func makeUIView(context: Context) -> RemoteGestureView {
        let view = RemoteGestureView()
        update(view)
        return view
    }

    func updateUIView(_ uiView: RemoteGestureView, context: Context) {
        update(uiView)
    }

    static func dismantleUIView(_ view: RemoteGestureView, coordinator: Void) {
        view.finishDraggingIfNeeded()
    }

    private func update(_ view: RemoteGestureView) {
        view.configure(streamID: streamID, enabled: enabled)
        view.onMove = onMove
        view.onTap = onTap
        view.onRightTap = onRightTap
        view.onScroll = onScroll
        view.onDragChanged = onDragChanged
    }
}

final class RemoteGestureView: UIView, UIGestureRecognizerDelegate {
    var onMove: ((Double, Double) -> Void)?
    var onTap: (() -> Void)?
    var onRightTap: (() -> Void)?
    var onScroll: ((Double, Double) -> Void)?
    var onDragChanged: ((Bool) -> Void)?

    private var isDragging = false
    private var streamID: UUID?
    private var pointerPan: UIPanGestureRecognizer?

    func configure(streamID: UUID?, enabled: Bool) {
        if self.streamID != streamID || !enabled {
            finishDraggingIfNeeded()
            for gesture in gestureRecognizers ?? [] where gesture.isEnabled {
                gesture.isEnabled = false
                gesture.isEnabled = true
            }
        }
        self.streamID = streamID
        isUserInteractionEnabled = enabled
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        isAccessibilityElement = true
        accessibilityLabel = "远程触控板"
        accessibilityHint = "单指移动和点击，双指滚动和右键，长按后拖动"
        installRecognizers()
        NotificationCenter.default.addObserver(self, selector: #selector(finishDraggingIfNeeded),
            name: UIApplication.willResignActiveNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从编码器创建远程触控板")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            finishDraggingIfNeeded()
        }
    }

    private func installRecognizers() {
        let pointerPan = UIPanGestureRecognizer(target: self, action: #selector(handlePointerPan))
        pointerPan.minimumNumberOfTouches = 1
        pointerPan.maximumNumberOfTouches = 1
        pointerPan.delegate = self
        addGestureRecognizer(pointerPan)
        self.pointerPan = pointerPan

        let scrollPan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan))
        scrollPan.minimumNumberOfTouches = 2
        scrollPan.maximumNumberOfTouches = 2
        addGestureRecognizer(scrollPan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.numberOfTouchesRequired = 1
        addGestureRecognizer(tap)

        let rightTap = UITapGestureRecognizer(target: self, action: #selector(handleRightTap))
        rightTap.numberOfTouchesRequired = 2
        addGestureRecognizer(rightTap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        longPress.minimumPressDuration = 0.35
        longPress.allowableMovement = 28
        longPress.numberOfTouchesRequired = 1
        longPress.delegate = self
        addGestureRecognizer(longPress)

        tap.require(toFail: longPress)
    }

    @objc private func handlePointerPan(_ recognizer: UIPanGestureRecognizer) {
        sendPendingPointerMovement(recognizer)
    }

    private func sendPendingPointerMovement(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        if recognizer.state == .began || recognizer.state == .changed || recognizer.state == .ended {
            if abs(translation.x) + abs(translation.y) > 0.2 {
                onMove?(Double(translation.x) * 1.25, Double(translation.y) * 1.25)
                recognizer.setTranslation(.zero, in: self)
            }
        }
    }

    @objc private func handleScrollPan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        if recognizer.state == .began || recognizer.state == .changed {
            finishDraggingIfNeeded()
            if abs(translation.x) + abs(translation.y) > 0.2 {
                onScroll?(Double(translation.x) * 1.5, Double(translation.y) * 1.5)
                recognizer.setTranslation(.zero, in: self)
            }
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        onTap?()
    }

    @objc private func handleRightTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        onRightTap?()
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            beginDraggingIfNeeded()
        case .changed:
            if recognizer.numberOfTouches != 1 { finishDraggingIfNeeded() }
        case .ended, .cancelled, .failed:
            finishDraggingIfNeeded()
        default:
            break
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        let hasLongPress = gestureRecognizer is UILongPressGestureRecognizer
            || otherGestureRecognizer is UILongPressGestureRecognizer
        let hasOneFingerPan = [gestureRecognizer, otherGestureRecognizer].contains { recognizer in
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            return pan.maximumNumberOfTouches == 1
        }
        return hasLongPress && hasOneFingerPan
            && gestureRecognizer.view === self && otherGestureRecognizer.view === self
    }

    func beginDraggingIfNeeded() {
        guard isUserInteractionEnabled, !isDragging else { return }
        isDragging = true
        onDragChanged?(true)
    }

    @objc func finishDraggingIfNeeded() {
        guard isDragging else { return }
        // 长按和移动可能以不同顺序结束，先取完最后位移再松开按键。
        if let pointerPan { sendPendingPointerMovement(pointerPan) }
        isDragging = false
        onDragChanged?(false)
    }
}
