import Foundation

public enum VideoOutputSizingPolicy {
    public static let maximumSide = 3_840
    public static let maximumPixelCount = 3_840 * 2_160

    public static func normalizedRequest(_ requested: StreamDimensions) -> StreamDimensions {
        let width = Double(max(2, requested.width))
        let height = Double(max(2, requested.height))
        let scale = min(
            1,
            Double(maximumSide) / width,
            Double(maximumSide) / height,
            sqrt(Double(maximumPixelCount) / (width * height))
        )
        return evenDimensions(width: width * scale, height: height * scale)
    }

    public static func nativePixelDimensions(
        pointWidth: Int,
        pointHeight: Int,
        pointPixelScale: Double
    ) -> StreamDimensions? {
        guard pointWidth > 0,
              pointHeight > 0,
              pointPixelScale.isFinite,
              pointPixelScale > 0 else { return nil }
        return evenDimensions(
            width: Double(pointWidth) * pointPixelScale,
            height: Double(pointHeight) * pointPixelScale
        )
    }

    public static func aspectFit(
        source: StreamDimensions,
        within maximum: StreamDimensions
    ) -> StreamDimensions {
        let sourceWidth = Double(max(2, source.width))
        let sourceHeight = Double(max(2, source.height))
        let maximumWidth = Double(max(2, maximum.width))
        let maximumHeight = Double(max(2, maximum.height))
        let scale = min(
            1,
            maximumWidth / sourceWidth,
            maximumHeight / sourceHeight
        )
        return evenDimensions(width: sourceWidth * scale, height: sourceHeight * scale)
    }

    private static func evenDimensions(width: Double, height: Double) -> StreamDimensions {
        StreamDimensions(
            width: max(2, Int(width.rounded())) & ~1,
            height: max(2, Int(height.rounded())) & ~1
        )
    }
}
