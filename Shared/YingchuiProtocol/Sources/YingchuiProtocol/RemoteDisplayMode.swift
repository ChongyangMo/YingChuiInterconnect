import Foundation

/// 用户意图只有复制和扩展；独立桌面由 Mac 的真实硬件状态决定。
public enum RemoteDisplayMode: String, Codable, CaseIterable, Sendable {
    case mirror, extended, standalone
    public var title: String {
        switch self { case .mirror: "复制"; case .extended: "扩展"; case .standalone: "独立桌面" }
    }
}

public enum RemoteDisplayPlacement: String, Codable, CaseIterable, Sendable {
    case left, right, above, below
    public var title: String {
        switch self { case .left: "左侧"; case .right: "右侧"; case .above: "上方"; case .below: "下方" }
    }
}

public struct RemoteDisplayState: Codable, Equatable, Sendable {
    public let mode: RemoteDisplayMode
    public let placement: RemoteDisplayPlacement?
    public init(mode: RemoteDisplayMode, placement: RemoteDisplayPlacement? = nil) {
        self.mode = mode
        self.placement = placement
    }
    public var isValid: Bool { (mode == .extended) == (placement != nil) }
}
