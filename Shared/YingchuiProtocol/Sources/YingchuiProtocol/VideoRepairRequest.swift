import Foundation

/// 经已认证的控制连接请求缺片；原始加密数据仍通过视频通道发送。
public struct VideoRepairRequest: Codable, Equatable, Sendable {
    public static let maximumPacketCount = 256
    public let frameID: UInt32
    public let fragmentIndices: [UInt16]?

    public init(frameID: UInt32, fragmentIndices: [UInt16]?) {
        self.frameID = frameID
        self.fragmentIndices = fragmentIndices
    }

    public var isValid: Bool {
        guard let fragmentIndices else { return true }
        return !fragmentIndices.isEmpty && fragmentIndices.count <= Self.maximumPacketCount
            && Set(fragmentIndices).count == fragmentIndices.count
            && fragmentIndices.allSatisfy { Int($0) < VideoDatagramCodec.maximumFragmentsPerFrame }
    }
}
