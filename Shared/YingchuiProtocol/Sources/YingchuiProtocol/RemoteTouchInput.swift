import Foundation

public enum RemoteTouchPhase: String, Codable, Sendable {
    case tap, rightTap, dragBegan, dragMoved, dragEnded, scroll, hover
    public var isDrag: Bool { self == .dragBegan || self == .dragMoved || self == .dragEnded }
}

public enum RemoteScrollPhase: String, Codable, Sendable {
    case began, changed, ended, cancelled, momentumBegan, momentumChanged, momentumEnded
    public var isMomentum: Bool { self == .momentumBegan || self == .momentumChanged || self == .momentumEnded }
    public var isTerminal: Bool { self == .ended || self == .cancelled || self == .momentumEnded }
}

/// 坐标相对于实际视频内容，范围 0...1，与 iPad 像素倍率无关。
public struct RemoteTouchInput: Codable, Equatable, Sendable {
    public let phase: RemoteTouchPhase
    public let x: Double
    public let y: Double
    public let gestureID: UUID?
    public let deltaX: Double?
    public let deltaY: Double?
    /// 可选字段，旧客户端仍可发送没有阶段的滚轮事件。
    public let scrollPhase: RemoteScrollPhase?

    public init(phase: RemoteTouchPhase, x: Double, y: Double, gestureID: UUID? = nil,
                deltaX: Double? = nil, deltaY: Double? = nil, scrollPhase: RemoteScrollPhase? = nil) {
        self.phase = phase
        self.x = x
        self.y = y
        self.gestureID = gestureID
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.scrollPhase = scrollPhase
    }

    public func validate() throws {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw RemoteControlValidationError.invalidCoordinate
        }
        guard phase.isDrag == (gestureID != nil) else { throw RemoteControlValidationError.missingField }
        if phase == .scroll {
            guard let deltaX, let deltaY else { throw RemoteControlValidationError.missingField }
            guard deltaX.isFinite, deltaY.isFinite, abs(deltaX) <= 300, abs(deltaY) <= 300 else {
                throw RemoteControlValidationError.invalidCoordinate
            }
        } else if deltaX != nil || deltaY != nil || scrollPhase != nil { throw RemoteControlValidationError.unsupportedKind }
    }
}
