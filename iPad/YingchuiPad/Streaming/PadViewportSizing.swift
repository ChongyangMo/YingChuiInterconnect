import CoreGraphics
import YingchuiProtocol

enum PadViewportSizing {
    static func pixelDimensions(
        pointSize: CGSize,
        nativeScale: CGFloat
    ) -> StreamDimensions? {
        guard pointSize.width.isFinite,
              pointSize.height.isFinite,
              nativeScale.isFinite,
              pointSize.width > 0,
              pointSize.height > 0,
              nativeScale > 0 else { return nil }
        return StreamDimensions(
            width: max(2, Int((pointSize.width * nativeScale).rounded())) & ~1,
            height: max(2, Int((pointSize.height * nativeScale).rounded())) & ~1
        )
    }
}
