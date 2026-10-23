import CoreGraphics
import Foundation
import YingchuiProtocol

/// 首次移动立即交付，后续增量按显示节奏合并；小数余量保留到下一次交付。
@MainActor
final class DirectTouchScrollSession {
    var onSend: ((CGPoint, CGPoint, RemoteScrollPhase) -> Void)?
    var onNeedsFrames: ((Bool) -> Void)?
    private(set) var anchor: CGPoint?
    private(set) var isDecelerating = false
    private var pending = CGPoint.zero
    private var remainder = CGPoint.zero
    private var firstMovement = true
    private var velocity = CGPoint.zero
    private var previousTime: TimeInterval = 0
    private var elapsed: TimeInterval = 0
    var isActive: Bool { anchor != nil }

    func begin(at point: CGPoint) {
        cancel()
        anchor = point
        pending = .zero
        remainder = .zero
        firstMovement = true
        send(.zero, phase: .began)
        onNeedsFrames?(true)
    }

    func move(by delta: CGPoint) {
        guard isActive, !isDecelerating, delta.x.isFinite, delta.y.isFinite else { return }
        pending.x += min(300, max(-300, delta.x * 1.5))
        pending.y += min(300, max(-300, delta.y * 1.5))
        if firstMovement, delta != .zero {
            firstMovement = false
            flush(phase: .changed)
        }
    }

    func end(velocity: CGPoint = .zero, allowsMomentum: Bool = false,
             now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard isActive, !isDecelerating else { return }
        flush(phase: .changed)
        send(.zero, phase: .ended)
        guard allowsMomentum, now.isFinite, velocity.x.isFinite, velocity.y.isFinite,
              hypot(velocity.x, velocity.y) >= 80 else { finish(); return }
        let speed = hypot(velocity.x, velocity.y)
        let scale = min(1.5, 2400 / speed)
        self.velocity = CGPoint(x: velocity.x * scale, y: velocity.y * scale)
        isDecelerating = true
        previousTime = now
        elapsed = 0
        send(.zero, phase: .momentumBegan)
    }

    func tick(now: TimeInterval) {
        guard isActive else { return }
        guard isDecelerating else { flush(phase: .changed); return }
        let dt = now - previousTime
        // 停顿后直接结束，避免把积压的惯性位移一次补出来。
        guard dt.isFinite, dt > 0, dt <= 0.1 else { cancel(); return }
        previousTime = now
        elapsed += dt
        let decay = exp(-8.5 * dt)
        pending.x += velocity.x * (1 - decay) / 8.5
        pending.y += velocity.y * (1 - decay) / 8.5
        velocity.x *= decay
        velocity.y *= decay
        flush(phase: .momentumChanged)
        if hypot(velocity.x, velocity.y) < 12 || elapsed >= 1.2 {
            send(.zero, phase: .momentumEnded)
            finish()
        }
    }

    func cancel() {
        guard isActive else { return }
        // 取消时丢弃未发送位移，再次落指立即制动。
        send(.zero, phase: isDecelerating ? .momentumEnded : .cancelled)
        finish()
    }

    private func flush(phase: RemoteScrollPhase) {
        remainder.x = min(300, max(-300, remainder.x + pending.x))
        remainder.y = min(300, max(-300, remainder.y + pending.y))
        pending = .zero
        let delta = CGPoint(x: min(300, max(-300, remainder.x.rounded(.towardZero))),
                            y: min(300, max(-300, remainder.y.rounded(.towardZero))))
        remainder.x -= delta.x
        remainder.y -= delta.y
        if delta != .zero { send(delta, phase: phase) }
    }

    private func send(_ delta: CGPoint, phase: RemoteScrollPhase) {
        guard let anchor else { return }
        onSend?(anchor, delta, phase)
    }

    private func finish() {
        anchor = nil
        isDecelerating = false
        pending = .zero
        remainder = .zero
        velocity = .zero
        onNeedsFrames?(false)
    }
}
