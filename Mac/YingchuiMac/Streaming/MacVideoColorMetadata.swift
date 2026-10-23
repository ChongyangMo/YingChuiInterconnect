import AVFoundation
import VideoToolbox
import YingchuiProtocol

extension MacScreenStreamer {
    /// 使用真实采集缓冲区的标签，不猜测色域或传递函数。
    func applyCapturedColorMetadata(_ image: CVPixelBuffer) {
        guard !didApplyCaptureColorMetadata, let compressionSession else { return }
        didApplyCaptureColorMetadata = true
        var format: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: image, formatDescriptionOut: &format)
        guard status == noErr, let format else {
            eventLog.record("读取采集颜色标签失败：\(status)")
            return
        }
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        let fields: [(CFString, CFString, String)] = [
            (kCMFormatDescriptionExtension_ColorPrimaries, kVTCompressionPropertyKey_ColorPrimaries, "原色"),
            (kCMFormatDescriptionExtension_TransferFunction, kVTCompressionPropertyKey_TransferFunction, "传递"),
            (kCMFormatDescriptionExtension_YCbCrMatrix, kVTCompressionPropertyKey_YCbCrMatrix, "矩阵")
        ]
        var applied: [String] = []
        for (source, target, label) in fields {
            guard let value = extensions[source as String] as? String else { continue }
            let result = VTSessionSetProperty(compressionSession, key: target, value: value as CFString)
            if result == noErr { applied.append("\(label) \(value)") }
            else { eventLog.record("编码器无法保留采集颜色标签：\(label)，错误码 \(result)") }
        }
        if !applied.isEmpty {
            eventLog.record("已将真实采集颜色标签传入编码器：\(applied.joined(separator: "，"))")
        }
    }
}
