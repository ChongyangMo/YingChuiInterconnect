import AVFoundation
import UIKit
import YingchuiProtocol

final class PadCursorOverlayView: UIView {
    weak var model: PadCursorModel?
    private let clipLayer = CALayer()
    let cursorLayer = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        clipLayer.masksToBounds = true
        cursorLayer.anchorPoint = .zero
        layer.addSublayer(clipLayer)
        clipLayer.addSublayer(cursorLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不支持从编码器创建光标图层") }

    override func layoutSubviews() { super.layoutSubviews(); refresh() }

    func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let model, model.shouldDisplay, let point = model.position,
              let capture = model.captureBounds, capture.contains(point),
              let shape = model.shape, let image = model.image, bounds.width > 0, bounds.height > 0 else {
            cursorLayer.isHidden = true
            return
        }
        let content = AVMakeRect(aspectRatio: CGSize(width: capture.width, height: capture.height), insideRect: bounds)
        let scale = content.width / capture.width
        clipLayer.frame = content
        cursorLayer.contents = image
        cursorLayer.bounds = CGRect(x: 0, y: 0, width: shape.width * scale, height: shape.height * scale)
        cursorLayer.position = CGPoint(x: (point.x - capture.x - shape.hotSpot.x) * scale,
                                       y: (point.y - capture.y - shape.hotSpot.y) * scale)
        cursorLayer.isHidden = false
    }
}
