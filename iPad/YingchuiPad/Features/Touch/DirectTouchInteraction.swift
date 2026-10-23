import CoreGraphics
import Foundation
import YingchuiProtocol

enum DirectTouchGeometry {
    static func point(_ location: CGPoint, in size: CGSize, aspectRatio: Double?, clamped: Bool = false) -> CGPoint? {
        guard location.x.isFinite, location.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, let aspectRatio, aspectRatio.isFinite, aspectRatio > 0 else { return nil }
        let width = min(size.width, size.height * aspectRatio)
        let height = width / aspectRatio
        let rect = CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
        guard clamped || (location.x >= rect.minX && location.x <= rect.maxX
                          && location.y >= rect.minY && location.y <= rect.maxY) else { return nil }
        return CGPoint(x: min(1, max(0, (location.x - rect.minX) / width)),
                       y: min(1, max(0, (location.y - rect.minY) / height)))
    }
}

@MainActor
final class DirectTouchInteraction {
    var size: CGSize = .zero
    var aspectRatio: Double?
    var onSend: ((RemoteTouchInput) -> Void)?
    private var drag: (id: UUID, point: CGPoint)?
    private var hovering = false
    private var hold: (anchor: CGPoint, dragging: Bool)?
    private(set) lazy var fingerScroll = DirectTouchScrollSession()

    func beginFingerScroll(at location: CGPoint) {
        guard !fingerScroll.isActive, hold == nil, drag == nil, !hovering, mapped(location) != nil else { return }
        fingerScroll.onSend = { [weak self] anchor, delta, phase in
            self?.scroll(at: anchor, translation: delta, scrollPhase: phase)
        }
        fingerScroll.begin(at: location)
    }

    func moveFingerScroll(by translation: CGPoint) {
        fingerScroll.move(by: translation)
    }

    func endFingerScroll() { fingerScroll.end() }
    func cancelFingerScroll() { fingerScroll.cancel() }

    /// 静止长按保留悬停；移动超过手指抖动范围后，从原位置按下并拖动。
    func beginHold(at location: CGPoint) {
        guard !fingerScroll.isActive, hold == nil, drag == nil, !hovering, mapped(location) != nil else { return }
        hold = (location, false)
        beginHover(at: location)
    }

    func moveHold(to location: CGPoint) {
        guard let hold, mapped(location, clamped: true) != nil else { return }
        if !hold.dragging {
            guard hypot(location.x - hold.anchor.x, location.y - hold.anchor.y) >= 8 else { return }
            endHover()
            beginDrag(at: hold.anchor)
            self.hold = (hold.anchor, true)
        }
        moveDrag(to: location)
    }

    func endHold(at location: CGPoint? = nil) {
        guard hold != nil else { return }
        if let location { moveHold(to: location) }
        hold = nil
        endHover()
        endDrag(at: location)
    }

    func beginHover(at location: CGPoint) {
        guard !fingerScroll.isActive, drag == nil, !hovering, let point = mapped(location) else { return }
        hovering = true
        onSend?(RemoteTouchInput(phase: .hover, x: point.x, y: point.y))
    }

    func moveHover(to location: CGPoint) {
        guard hovering, let point = mapped(location, clamped: true) else { return }
        onSend?(RemoteTouchInput(phase: .hover, x: point.x, y: point.y))
    }

    /// 松手只结束触屏手势，鼠标留在目标上，菜单保持展开供下一次点选。
    func endHover() { hovering = false }

    func tap(at location: CGPoint, right: Bool = false) {
        guard !fingerScroll.isActive, drag == nil, !hovering, let point = mapped(location) else { return }
        onSend?(RemoteTouchInput(phase: right ? .rightTap : .tap, x: point.x, y: point.y))
    }

    func beginDrag(at location: CGPoint) {
        guard !fingerScroll.isActive, drag == nil, !hovering, let point = mapped(location) else { return }
        let id = UUID()
        drag = (id, point)
        onSend?(RemoteTouchInput(phase: .dragBegan, x: point.x, y: point.y, gestureID: id))
    }

    func moveDrag(to location: CGPoint) {
        guard let drag, let point = mapped(location, clamped: true) else { return }
        self.drag = (drag.id, point)
        onSend?(RemoteTouchInput(phase: .dragMoved, x: point.x, y: point.y, gestureID: drag.id))
    }

    func endDrag(at location: CGPoint? = nil) {
        guard let drag else { return }
        let point = location.flatMap { mapped($0, clamped: true) } ?? drag.point
        self.drag = nil
        onSend?(RemoteTouchInput(phase: .dragEnded, x: point.x, y: point.y, gestureID: drag.id))
    }

    func scroll(at location: CGPoint, translation: CGPoint, scrollPhase: RemoteScrollPhase? = nil) {
        endHold()
        endHover()
        endDrag()
        guard let point = mapped(location), translation.x.isFinite, translation.y.isFinite else { return }
        let scale = scrollPhase == nil ? 1.5 : 1
        onSend?(RemoteTouchInput(phase: .scroll, x: point.x, y: point.y,
            deltaX: min(300, max(-300, translation.x * scale)), deltaY: min(300, max(-300, translation.y * scale)),
            scrollPhase: scrollPhase))
    }

    private func mapped(_ location: CGPoint, clamped: Bool = false) -> CGPoint? {
        DirectTouchGeometry.point(location, in: size, aspectRatio: aspectRatio, clamped: clamped)
    }
}
