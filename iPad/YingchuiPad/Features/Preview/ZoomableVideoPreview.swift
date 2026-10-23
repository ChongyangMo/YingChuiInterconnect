import AVFoundation
import SwiftUI
import YingchuiProtocol

struct ZoomableVideoPreview: UIViewRepresentable {
    let renderer: VideoRenderer
    let aspectRatio: Double?
    let streamID: UUID?
    let touchEnabled: Bool
    let onSend: (RemoteTouchInput) -> Void

    func makeUIView(context: Context) -> VideoPreviewZoomView { VideoPreviewZoomView() }

    func updateUIView(_ view: VideoPreviewZoomView, context: Context) {
        if view.video.renderer !== renderer {
            view.video.renderer?.detach(view.video.sampleBufferLayer)
            view.video.renderer = renderer
        }
        renderer.attach(view.video.sampleBufferLayer, videoGravity: .resizeAspect)
        view.configure(aspectRatio: aspectRatio, streamID: streamID, touchEnabled: touchEnabled, onSend: onSend)
    }

    static func dismantleUIView(_ view: VideoPreviewZoomView, coordinator: Void) {
        view.touch.cancelInteraction()
        view.video.renderer?.detach(view.video.sampleBufferLayer)
        view.video.sampleBufferLayer.flushAndRemoveImage()
    }
}
