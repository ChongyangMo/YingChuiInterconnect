#if DEBUG
import AVFoundation
import UIKit
import YingchuiProtocol

@MainActor
struct PadVideoInvestigationProbe {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--video-investigation")
    var recordedImage = false
    var streamID: UUID?
    var lastLayout: String?

    mutating func configure(streamID: UUID, description: CMFormatDescription, log: DiagnosticEventLog) {
        self = Self()
        self.streamID = streamID
        guard Self.enabled else { return }
        log.record("视频颜色调查：解码输入，流 \(streamID)，\(VideoColorDiagnostics.describe(description))")
    }

    mutating func image(_ image: CVPixelBuffer, log: DiagnosticEventLog) {
        guard Self.enabled, !recordedImage else { return }
        recordedImage = true
        log.record("视频颜色调查：解码像素，\(VideoColorDiagnostics.describe(image))")
    }

    mutating func layout(size: CGSize, scale: CGFloat, log: DiagnosticEventLog) {
        guard Self.enabled, let streamID, size.width > 0, size.height > 0 else { return }
        let value = "流 \(streamID)，表面 \(size.width)×\(size.height) 点，原生缩放 \(scale)，物理表面 \(size.width * scale)×\(size.height * scale) 像素"
        guard lastLayout != value else { return }
        lastLayout = value
        log.record("显示映射调查：\(value)")
    }
}
#endif
