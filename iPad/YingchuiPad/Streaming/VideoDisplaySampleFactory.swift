import AVFoundation

/// 交互回传优先响应：每个真实解码样本立即提交，不设置未来播放期限。
enum VideoDisplaySampleFactory {
    static func make(image: CVPixelBuffer, sourceMicroseconds: UInt64) throws -> CMSampleBuffer {
        var description: CMVideoFormatDescription?
        var status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &description
        )
        guard status == noErr, let description else { throw VideoRendererError.formatDescription(status) }
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(clamping: sourceMicroseconds), timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: description,
            sampleTiming: &timing, sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { throw VideoRendererError.sampleBuffer(status) }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
