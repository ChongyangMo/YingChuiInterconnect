import Foundation

public enum StreamQualityPreset: String, CaseIterable, Identifiable, Sendable {
    case smooth = "流畅"
    case balanced = "均衡"
    case sharp = "清晰"
    case native = "原生"

    public var id: String { rawValue }

    public var frameRate: Int {
        switch self {
        case .smooth: 30
        case .balanced, .sharp: 60
        case .native: 120
        }
    }

    public var bitRate: Int {
        bitRate(frameRate: frameRate)
    }

    public func frameRate(maximumSupportedFrameRate: Int) -> Int {
        min(frameRate, VideoStreamLimits.normalizedFrameRate(maximumSupportedFrameRate))
    }

    public func bitRate(frameRate: Int) -> Int {
        switch self {
        case .smooth: return 6_000_000
        case .balanced: return 10_000_000
        case .sharp: return 16_000_000
        case .native:
            let normalizedFrameRate = VideoStreamLimits.normalizedFrameRate(frameRate)
            let scaledBitRate = Int(
                (30_000_000.0 * Double(normalizedFrameRate) / 60).rounded(.up)
            )
            return VideoStreamLimits.normalizedBitRate(scaledBitRate)
        }
    }

    public func dimensions(nativeWidth: Int, nativeHeight: Int) -> StreamDimensions {
        let width = max(2, nativeWidth)
        let height = max(2, nativeHeight)
        let nativeLongEdge = max(width, height)
        let targetLongEdge = min(nativeLongEdge, maximumLongEdge ?? nativeLongEdge)
        let scale = Double(targetLongEdge) / Double(nativeLongEdge)
        return StreamDimensions(
            width: max(2, Int((Double(width) * scale).rounded())) & ~1,
            height: max(2, Int((Double(height) * scale).rounded())) & ~1
        )
    }

    public static func resolutionOptions(viewport: StreamDimensions) -> [StreamQualityPreset] {
        var seenDimensions = Set<StreamDimensions>()
        let highestQualityFirst = allCases.reversed().filter { quality in
            let dimensions = quality.dimensions(
                nativeWidth: viewport.width,
                nativeHeight: viewport.height
            )
            return seenDimensions.insert(dimensions).inserted
        }
        return Array(highestQualityFirst.reversed())
    }

    public func lowerQuality() -> StreamQualityPreset? {
        switch self {
        case .native: .sharp
        case .sharp: .balanced
        case .balanced: .smooth
        case .smooth: nil
        }
    }

    public func higherQuality(upTo ceiling: StreamQualityPreset) -> StreamQualityPreset? {
        let candidate: StreamQualityPreset? = switch self {
        case .smooth: .balanced
        case .balanced: .sharp
        case .sharp: .native
        case .native: nil
        }
        guard let candidate, candidate.rank <= ceiling.rank else { return nil }
        return candidate
    }

    private var maximumLongEdge: Int? {
        switch self {
        case .smooth: 1_280
        case .balanced: 1_920
        case .sharp: 2_560
        case .native: nil
        }
    }

    private var rank: Int {
        switch self {
        case .smooth: 0
        case .balanced: 1
        case .sharp: 2
        case .native: 3
        }
    }
}

public struct StreamDimensions: Equatable, Hashable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct StreamRequest: Equatable, Sendable {
    public let displayMode: RemoteDisplayMode
    public let displayPlacement: RemoteDisplayPlacement
    public let viewport: StreamDimensions
    public let dimensions: StreamDimensions
    public let frameRate: Int
    public let bitRate: Int

    public init(
        quality: StreamQualityPreset,
        viewport: StreamDimensions,
        maximumFrameRate: Int = 60,
        displayMode: RemoteDisplayMode = .mirror,
        displayPlacement: RemoteDisplayPlacement = .right
    ) {
        self.displayMode = displayMode
        self.displayPlacement = displayPlacement
        self.viewport = viewport
        dimensions = quality.dimensions(
            nativeWidth: viewport.width,
            nativeHeight: viewport.height
        )
        frameRate = quality.frameRate(maximumSupportedFrameRate: maximumFrameRate)
        bitRate = quality.bitRate(frameRate: frameRate)
    }
}

public struct AdaptiveStreamPolicy: Sendable {
    public private(set) var ceiling: StreamQualityPreset = .native
    public private(set) var current: StreamQualityPreset = .native
    private var healthyIntervals = 0
    private var poorIntervals = 0

    public init() {}

    public mutating func reset(ceiling: StreamQualityPreset) {
        self.ceiling = ceiling
        current = ceiling
        healthyIntervals = 0
        poorIntervals = 0
    }

    public mutating func evaluate(
        lossRate: Double,
        roundTripP95Milliseconds: Double?,
        videoLatencyP95Milliseconds: Double?
    ) -> StreamQualityPreset? {
        let roundTrip = roundTripP95Milliseconds ?? 0
        let videoLatency = videoLatencyP95Milliseconds ?? 0
        let isCritical = lossRate >= 0.05 || roundTrip >= 50 || videoLatency >= 120
        let isPoor = lossRate >= 0.02 || roundTrip >= 35 || videoLatency >= 85
        let isHealthy = lossRate < 0.005 && roundTrip < 20 && videoLatency < 65

        if isPoor {
            poorIntervals += 1
            healthyIntervals = 0
            guard isCritical || poorIntervals >= 2, let next = current.lowerQuality() else { return nil }
            current = next
            poorIntervals = 0
            return next
        }

        poorIntervals = 0
        guard isHealthy else {
            healthyIntervals = 0
            return nil
        }

        healthyIntervals += 1
        guard healthyIntervals >= 8, let next = current.higherQuality(upTo: ceiling) else { return nil }
        current = next
        healthyIntervals = 0
        return next
    }

    public mutating func evaluateStall() -> StreamQualityPreset? {
        evaluate(
            lossRate: 1,
            roundTripP95Milliseconds: nil,
            videoLatencyP95Milliseconds: nil
        )
    }
}
