import CoreGraphics
import UIKit
import YingchuiProtocol

struct PadDisplayCapabilities: Equatable {
    let viewport: StreamDimensions
    let maximumFrameRate: Int

    @MainActor
    static func active(
        viewSize: CGSize? = nil,
        nativeScale: CGFloat? = nil
    ) -> PadDisplayCapabilities? {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            return nil
        }
        let pointSize = viewSize
            ?? windowScene.windows.first(where: \.isKeyWindow)?.bounds.size
            ?? windowScene.windows.first?.bounds.size
        guard let pointSize,
              let viewport = PadViewportSizing.pixelDimensions(
                  pointSize: pointSize,
                  nativeScale: nativeScale ?? windowScene.screen.nativeScale
              ),
              windowScene.screen.maximumFramesPerSecond
                >= VideoStreamLimits.minimumFrameRate else {
            return nil
        }
        return PadDisplayCapabilities(
            viewport: viewport,
            maximumFrameRate: VideoStreamLimits.normalizedFrameRate(
                windowScene.screen.maximumFramesPerSecond
            )
        )
    }
}
