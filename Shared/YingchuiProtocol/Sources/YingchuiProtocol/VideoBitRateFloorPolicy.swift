import Foundation

public enum VideoBitRateFloorPolicy {
    private static let minimumSupportedBitRate = 4_000_000
    private static let bitsPerPixelPerFrame = 0.075
    private static let roundingStep = 500_000

    public static func minimumBitRate(
        dimensions: StreamDimensions,
        frameRate: Int,
        maximumBitRate: Int,
        constrainedNetwork: Bool = false
    ) -> Int {
        let ceiling = VideoStreamLimits.normalizedBitRate(maximumBitRate)
        // 无线拥塞时允许降低压缩码率，保留分辨率与刷新率，避免卡在 Retina 画质下限。
        if constrainedNetwork { return min(ceiling, minimumSupportedBitRate) }
        let normalizedDimensions = VideoOutputSizingPolicy.normalizedRequest(dimensions)
        let pixelsPerFrame = Double(normalizedDimensions.width)
            * Double(normalizedDimensions.height)
        let framesPerSecond = Double(VideoStreamLimits.normalizedFrameRate(frameRate))
        let calculated = Int((pixelsPerFrame * framesPerSecond * bitsPerPixelPerFrame).rounded(.up))
        let rounded = ((calculated + roundingStep - 1) / roundingStep) * roundingStep
        return min(ceiling, max(minimumSupportedBitRate, rounded))
    }
}
