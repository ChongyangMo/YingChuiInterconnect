import ApplicationServices
import YingchuiProtocol

enum MacTouchEventFactory {
    static func position(for input: RemoteTouchInput, bounds: CGRect) throws -> CGPoint {
        try input.validate()
        guard bounds.minX.isFinite, bounds.minY.isFinite, bounds.width.isFinite, bounds.height.isFinite,
              bounds.width >= 1, bounds.height >= 1 else { throw TouchError.invalidDisplay }
        return CGPoint(x: min(bounds.maxX - 1, bounds.minX + input.x * bounds.width),
                       y: min(bounds.maxY - 1, bounds.minY + input.y * bounds.height))
    }

    static func events(for input: RemoteTouchInput, bounds: CGRect, clickCount: Int = 1) throws -> [CGEvent] {
        let point = try position(for: input, bounds: bounds)
        func mouse(_ type: CGEventType, button: CGMouseButton = .left) throws -> CGEvent {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: point, mouseButton: button) else { throw TouchError.creation }
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
            return event
        }
        switch input.phase {
        case .hover:
            let event = try mouse(.mouseMoved)
            event.setIntegerValueField(.mouseEventClickState, value: 0)
            return [event]
        case .tap:
            return try [mouse(.mouseMoved), mouse(.leftMouseDown), mouse(.leftMouseUp)]
        case .rightTap:
            return try [mouse(.mouseMoved), mouse(.rightMouseDown, button: .right), mouse(.rightMouseUp, button: .right)]
        case .dragBegan:
            return try [mouse(.mouseMoved), mouse(.leftMouseDown)]
        case .dragMoved:
            return try [mouse(.leftMouseDragged)]
        case .dragEnded:
            return try [mouse(.leftMouseUp)]
        case .scroll:
            guard let x = input.deltaX, let y = input.deltaY,
                  let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                    wheel1: MacInputMapping.clampedScrollValue(y), wheel2: MacInputMapping.clampedScrollValue(x),
                    wheel3: 0) else { throw TouchError.creation }
            event.location = point
            if let phase = input.scrollPhase {
                let scroll: Int64
                let momentum: Int64
                switch phase {
                case .began: (scroll, momentum) = (Int64(CGScrollPhase.began.rawValue), 0)
                case .changed: (scroll, momentum) = (Int64(CGScrollPhase.changed.rawValue), 0)
                case .ended: (scroll, momentum) = (Int64(CGScrollPhase.ended.rawValue), 0)
                case .cancelled: (scroll, momentum) = (Int64(CGScrollPhase.cancelled.rawValue), 0)
                case .momentumBegan: (scroll, momentum) = (0, Int64(CGMomentumScrollPhase.begin.rawValue))
                case .momentumChanged: (scroll, momentum) = (0, Int64(CGMomentumScrollPhase.continuous.rawValue))
                case .momentumEnded: (scroll, momentum) = (0, Int64(CGMomentumScrollPhase.end.rawValue))
                }
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: scroll)
                event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            }
            return try [mouse(.mouseMoved), event]
        }
    }

    enum TouchError: LocalizedError {
        case invalidDisplay, creation
        var errorDescription: String? {
            switch self {
            case .invalidDisplay: "触摸目标显示器尺寸无效"
            case .creation: "无法创建 Mac 触摸控制事件"
            }
        }
    }
}

struct MacTouchClickSequence {
    private var previous: (point: CGPoint, time: TimeInterval)?
    mutating func clickCount(at point: CGPoint, now: TimeInterval, interval: TimeInterval) -> Int {
        guard let previous, now >= previous.time, now - previous.time <= interval,
              abs(point.x - previous.point.x) <= 5, abs(point.y - previous.point.y) <= 5 else {
            previous = (point, now)
            return 1
        }
        // 双击后下一次重新计算，避免三连点被当作第二次双击。
        self.previous = nil
        return 2
    }
}
