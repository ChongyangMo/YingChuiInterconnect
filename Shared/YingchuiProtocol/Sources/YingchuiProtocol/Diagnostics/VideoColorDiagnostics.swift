import AVFoundation

public enum VideoColorDiagnostics {
    public static func describe(_ description: CMFormatDescription) -> String {
        let fields: [(String, CFString)] = [
            ("原色", kCMFormatDescriptionExtension_ColorPrimaries),
            ("传递", kCMFormatDescriptionExtension_TransferFunction),
            ("矩阵", kCMFormatDescriptionExtension_YCbCrMatrix),
            ("全范围", kCMFormatDescriptionExtension_FullRangeVideo)
        ]
        let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any] ?? [:]
        return fields.map { label, key in
            "\(label) \(extensions[key as String].map { String(describing: $0) } ?? "未标记")"
        }.joined(separator: "，")
    }

    public static func describe(_ image: CVPixelBuffer) -> String {
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: image, formatDescriptionOut: &description)
        guard status == noErr, let description else { return "读取像素颜色信息失败：\(status)" }
        return "\(CVPixelBufferGetWidth(image))×\(CVPixelBufferGetHeight(image))，像素格式 \(CVPixelBufferGetPixelFormatType(image))，\(describe(description))"
    }
}
