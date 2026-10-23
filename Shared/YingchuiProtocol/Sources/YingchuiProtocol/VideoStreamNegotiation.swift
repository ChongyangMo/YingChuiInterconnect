import Foundation

public enum VideoCodec: String, Codable, CaseIterable, Sendable {
    case h264, hevc
    public var title: String { self == .hevc ? "HEVC" : "H.264" }
}

/// 接收端承诺接受的格式范围；未知硬件吞吐保持 nil，不以屏幕刷新率冒充实测解码能力。
public struct VideoDecodeCapability: Codable, Equatable, Sendable {
    public let codec: String
    public let maximumWidth: Int
    public let maximumHeight: Int
    public let maximumFrameRate: Int
    public let maximumPixelsPerSecond: Int?

    public init(codec: VideoCodec, maximumWidth: Int = VideoOutputSizingPolicy.maximumSide,
                maximumHeight: Int = VideoOutputSizingPolicy.maximumSide,
                maximumFrameRate: Int = VideoStreamLimits.maximumFrameRate,
                maximumPixelsPerSecond: Int? = nil) {
        self.codec = codec.rawValue
        self.maximumWidth = maximumWidth
        self.maximumHeight = maximumHeight
        self.maximumFrameRate = maximumFrameRate
        self.maximumPixelsPerSecond = maximumPixelsPerSecond
    }

    public var isValid: Bool {
        maximumWidth >= 2 && maximumHeight >= 2 && maximumFrameRate > 0
            && (maximumPixelsPerSecond.map { $0 >= 4 } ?? true)
    }
}

public struct VideoOperatingPoint: Equatable, Sendable {
    public let codec: VideoCodec
    public let dimensions: StreamDimensions
    public let frameRate: Int
    public let bitRate: Int
}

public enum VideoStreamNegotiation {
    public static func select(dimensions: StreamDimensions, frameRate: Int, bitRate: Int,
                              capabilities: [VideoDecodeCapability]?, hardwareHEVC: Bool) throws -> VideoOperatingPoint {
        let size = VideoOutputSizingPolicy.normalizedRequest(dimensions)
        let offers = capabilities ?? [VideoDecodeCapability(codec: .h264)]
        guard !offers.isEmpty, offers.count <= 16, offers.allSatisfy(\.isValid) else {
            throw VideoNegotiationError.invalidCapabilities
        }
        let codecs: [VideoCodec] = hardwareHEVC ? [.hevc, .h264] : [.h264]
        for codec in codecs {
            let rates = offers.filter { $0.codec == codec.rawValue }.compactMap { offer -> Int? in
                guard size.width <= offer.maximumWidth, size.height <= offer.maximumHeight else { return nil }
                var fps = min(VideoStreamLimits.normalizedFrameRate(frameRate), offer.maximumFrameRate)
                if let pixels = offer.maximumPixelsPerSecond {
                    fps = min(fps, pixels / (size.width * size.height))
                }
                if codec == .h264 { fps = h264FrameRate(dimensions: size, requested: fps) }
                return fps >= VideoStreamLimits.minimumFrameRate ? fps : nil
            }
            if let fps = rates.max() {
                return VideoOperatingPoint(codec: codec, dimensions: size, frameRate: fps,
                                           bitRate: VideoStreamLimits.normalizedBitRate(bitRate))
            }
        }
        throw VideoNegotiationError.noCompatibleConfiguration
    }

    /// H.264 High Level 5.2 的宏块吞吐边界，保留一帧余量；不代表特定硬件的实测速度。
    public static func h264FrameRate(dimensions: StreamDimensions, requested: Int) -> Int {
        guard (2...VideoOutputSizingPolicy.maximumSide).contains(dimensions.width),
              (2...VideoOutputSizingPolicy.maximumSide).contains(dimensions.height) else { return 0 }
        let blocks = ((dimensions.width + 15) / 16) * ((dimensions.height + 15) / 16)
        guard blocks > 0, blocks <= 36_864 else { return 0 }
        let limit = 2_073_600 / blocks
        return requested <= limit ? requested : max(0, limit - 1)
    }
}

public enum VideoNegotiationError: LocalizedError {
    case invalidCapabilities, noCompatibleConfiguration
    public var errorDescription: String? {
        switch self {
        case .invalidCapabilities: "接收端视频能力无效"
        case .noCompatibleConfiguration: "当前分辨率下没有双方支持的编码与帧率，请降低画质后重试"
        }
    }
}
