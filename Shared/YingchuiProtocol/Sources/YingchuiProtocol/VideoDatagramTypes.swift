import Foundation

public struct VideoFragment: Equatable, Sendable {
    public let streamID: UUID
    public let frameID: UInt32
    public let fragmentIndex: UInt16
    public let fragmentCount: UInt16
    public let presentationTimeMicroseconds: UInt64
    public let isKeyFrame: Bool
    public let payload: Data

    public init(
        streamID: UUID,
        frameID: UInt32,
        fragmentIndex: UInt16,
        fragmentCount: UInt16,
        presentationTimeMicroseconds: UInt64,
        isKeyFrame: Bool,
        payload: Data
    ) {
        self.streamID = streamID
        self.frameID = frameID
        self.fragmentIndex = fragmentIndex
        self.fragmentCount = fragmentCount
        self.presentationTimeMicroseconds = presentationTimeMicroseconds
        self.isKeyFrame = isKeyFrame
        self.payload = payload
    }
}

public struct CompletedVideoFrame: Equatable, Sendable {
    public let streamID: UUID
    public let frameID: UInt32
    public let presentationTimeMicroseconds: UInt64
    public let isKeyFrame: Bool
    public let accessUnit: Data
}

public enum VideoDatagramError: LocalizedError, Equatable {
    case datagramTooShort
    case invalidMagic
    case unsupportedVersion(UInt8)
    case invalidHeader
    case invalidPayloadLength
    case tooManyFragments
    case datagramTooLarge
    case accessUnitTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .datagramTooShort: "视频数据包长度不足"
        case .invalidMagic: "视频数据包标识无效"
        case .unsupportedVersion(let version): "不支持的视频数据包版本（\(version)）"
        case .invalidHeader: "视频数据包头无效"
        case .invalidPayloadLength: "视频数据包载荷长度不一致"
        case .tooManyFragments: "单帧视频分片数量超限"
        case .datagramTooLarge: "视频数据包超过网络安全上限"
        case .accessUnitTooLarge(let size): "单帧视频数据过大（\(size) 字节）"
        }
    }
}

