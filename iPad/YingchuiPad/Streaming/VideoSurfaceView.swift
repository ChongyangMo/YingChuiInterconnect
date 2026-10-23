import AVFoundation
import SwiftUI
import UIKit
import YingchuiProtocol

struct VideoSurfaceView: UIViewRepresentable {
    let renderer: VideoRenderer
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> SampleBufferView {
        let view = SampleBufferView()
        view.renderer = renderer
        renderer.attach(view.sampleBufferLayer, videoGravity: videoGravity)
        return view
    }

    func updateUIView(_ uiView: SampleBufferView, context: Context) {
        uiView.renderer = renderer
        renderer.attach(uiView.sampleBufferLayer, videoGravity: videoGravity)
    }

    static func dismantleUIView(_ uiView: SampleBufferView, coordinator: Void) {
        uiView.renderer?.detach(uiView.sampleBufferLayer)
        uiView.sampleBufferLayer.flushAndRemoveImage()
    }
}

final class SampleBufferView: UIView {
    weak var renderer: VideoRenderer? {
        didSet {
            guard oldValue !== renderer else { return }
            oldValue?.cursor.detach(cursorOverlay)
            renderer?.cursor.attach(cursorOverlay)
        }
    }
    private let cursorOverlay = PadCursorOverlayView()

    override func layoutSubviews() {
        super.layoutSubviews()
        cursorOverlay.frame = bounds
#if DEBUG
        if let renderer {
            renderer.investigation.layout(size: bounds.size, scale: window?.screen.nativeScale ?? contentScaleFactor,
                log: renderer.pipelineMetrics.log)
        }
#endif
    }

    private var readyObserver: VideoDisplayObservation?
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var sampleBufferLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(cursorOverlay)
        backgroundColor = .clear
        isOpaque = false
        if #available(iOS 17.4, *) {
            let observer = NotificationCenter.default.addObserver(
                forName: Notification.Name.AVSampleBufferDisplayLayerReadyForDisplayDidChange,
                object: sampleBufferLayer, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.sampleBufferLayer.isReadyForDisplay else { return }
                    self.renderer?.startupTrace?.mark("显示层首帧可显示")
                }
            }
            readyObserver = VideoDisplayObservation(observer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从编码器创建视频显示视图")
    }
}


/// 通知中心允许在任意线程取消注册，独立持有令牌以兼容视图释放。
private final class VideoDisplayObservation: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}
