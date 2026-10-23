import Foundation

/// 光标坐标使用 Mac 全局逻辑点；与视频编码分辨率和 iPad 缩放无关。
public struct RemoteCursorPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public var isValid: Bool { x.isFinite && y.isFinite && abs(x) <= 1_000_000 && abs(y) <= 1_000_000 }
}

public struct RemoteCursorRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var isValid: Bool {
        RemoteCursorPoint(x: x, y: y).isValid && width.isFinite && height.isFinite
            && (1...32_768).contains(width) && (1...32_768).contains(height)
    }
    public func contains(_ point: RemoteCursorPoint) -> Bool {
        point.x >= x && point.y >= y && point.x < x + width && point.y < y + height
    }
    public func clamped(_ point: RemoteCursorPoint) -> RemoteCursorPoint {
        .init(x: min(x + width - 1, max(x, point.x)), y: min(y + height - 1, max(y, point.y)))
    }
    public static func project(_ point: RemoteCursorPoint, onto displays: [Self]) -> RemoteCursorPoint? {
        guard point.isValid, !displays.isEmpty, displays.allSatisfy(\.isValid) else { return nil }
        if displays.contains(where: { $0.contains(point) }) { return point }
        return displays.map { $0.clamped(point) }.min {
            hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y)
        }
    }
}

public struct RemoteCursorInput: Codable, Equatable, Sendable {
    public let position: RemoteCursorPoint
    public let sequence: UInt64
    public init(position: RemoteCursorPoint, sequence: UInt64) { self.position = position; self.sequence = sequence }
    public var isValid: Bool { position.isValid && sequence > 0 && sequence < 0x0000_FFFF_FFFF_FFFF }
    // 注入事件携带序号；只有系统事件监听实际看见后，才向客户端确认位置。
    public var eventTag: Int64 { Int64(0x5943_0000_0000_0000 | sequence) }
    public static func sequence(fromEventTag tag: Int64) -> UInt64? {
        let bits = UInt64(bitPattern: tag)
        guard bits & 0xFFFF_0000_0000_0000 == 0x5943_0000_0000_0000 else { return nil }
        return bits & 0x0000_FFFF_FFFF_FFFF
    }
}

public struct RemoteCursorShape: Codable, Equatable, Sendable {
    public let png: Data
    public let width: Double
    public let height: Double
    public let hotSpot: RemoteCursorPoint
    public init(png: Data, width: Double, height: Double, hotSpot: RemoteCursorPoint) {
        self.png = png; self.width = width; self.height = height; self.hotSpot = hotSpot
    }
    public var isValid: Bool {
        !png.isEmpty && png.count <= 65_536 && width.isFinite && height.isFinite
            && (1...256).contains(width) && (1...256).contains(height)
            && hotSpot.isValid && (0...width).contains(hotSpot.x) && (0...height).contains(hotSpot.y)
    }
}

public struct RemoteCursorState: Codable, Equatable, Sendable {
    public let position: RemoteCursorPoint
    public let captureBounds: RemoteCursorRect
    public let displays: [RemoteCursorRect]
    public let visible: Bool
    public let acknowledgedInput: UInt64
    public let shape: RemoteCursorShape?
    public init(position: RemoteCursorPoint, captureBounds: RemoteCursorRect, displays: [RemoteCursorRect],
                visible: Bool, acknowledgedInput: UInt64, shape: RemoteCursorShape?) {
        self.position = position; self.captureBounds = captureBounds; self.displays = displays
        self.visible = visible; self.acknowledgedInput = acknowledgedInput; self.shape = shape
    }
    public var isValid: Bool {
        position.isValid && captureBounds.isValid && (1...16).contains(displays.count)
            && displays.allSatisfy(\.isValid) && (shape?.isValid ?? true)
            && acknowledgedInput < 0x0000_FFFF_FFFF_FFFF
    }
}
