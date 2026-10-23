import AVFoundation
import VideoToolbox
import YingchuiProtocol

private struct DecodedImage: @unchecked Sendable {
    // 回调持有像素缓冲区；跨队列后只读，交给显示层保留。
    let value: CVPixelBuffer
}

@MainActor
final class VideoFrameDecoder {
    var onFrame: ((CVPixelBuffer, CompletedVideoFrame) -> Void)?
    var onFailure: ((String) -> Void)?
    var onTiming: ((CompletedVideoFrame, VideoFrameDecodeTiming) -> Void)?
    private var session: VTDecompressionSession?
    private var generation = UUID()
    private let pendingFrames = SynchronizedValue(Set<UUID>())

    func configure(_ description: CMVideoFormatDescription) throws {
        reset()
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &created
        )
        guard status == noErr, let created else { throw VideoFrameDecoderError.creation(status) }
        let propertyStatus = VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        guard propertyStatus == noErr else {
            VTDecompressionSessionInvalidate(created)
            throw VideoFrameDecoderError.creation(propertyStatus)
        }
        session = created
    }

    func decode(_ sample: CMSampleBuffer, frame: CompletedVideoFrame, preparationStartedAt: UInt64? = nil) throws {
        guard let session else { throw VideoFrameDecoderError.notConfigured }
        let ticket = UUID()
        let pendingFrames = self.pendingFrames
        guard pendingFrames.mutate({ frames in
            // 允许硬件解码器冷启动时的短突发，同时限制未完成帧的内存占用。
            guard frames.count < 16 else { return false }
            frames.insert(ticket)
            return true
        }) else { throw VideoFrameDecoderError.queueFull }
        let currentGeneration = generation
        let submittedAt = DispatchTime.now().uptimeNanoseconds
        let pendingCount = pendingFrames.value.count
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil
        ) { [weak self] status, flags, image, _, _ in
            // 在解码回调中直接归还容量，不能排在主线程的新帧任务之后。
            guard pendingFrames.mutate({ $0.remove(ticket) != nil }) else { return }
            let callbackAt = DispatchTime.now().uptimeNanoseconds
            let output = image.map { DecodedImage(value: $0) }
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.onTiming?(frame, VideoFrameDecodeTiming(preparationStartedAt: preparationStartedAt ?? submittedAt,
                    submittedAt: submittedAt, callbackAt: callbackAt,
                    deliveredAt: DispatchTime.now().uptimeNanoseconds, pendingCount: pendingCount))
                guard status == noErr, !flags.contains(.frameDropped), let output else {
                    self.reset()
                    self.onFailure?("视频帧解码失败（\(status)）")
                    return
                }
                self.onFrame?(output.value, frame)
            }
        }
        guard status == noErr else {
            pendingFrames.mutate { $0.remove(ticket) }
            throw VideoFrameDecoderError.decode(status)
        }
    }

    func reset() {
        generation = UUID()
        pendingFrames.set([])
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
    }
}

struct VideoFrameDecodeTiming: Sendable {
    let preparationStartedAt: UInt64
    let submittedAt: UInt64
    let callbackAt: UInt64
    let deliveredAt: UInt64
    let pendingCount: Int
}

private enum VideoFrameDecoderError: LocalizedError {
    case creation(OSStatus)
    case decode(OSStatus)
    case notConfigured
    case queueFull

    var errorDescription: String? {
        switch self {
        case .creation(let status): "视频解码器初始化失败（\(status)）"
        case .decode(let status): "视频帧解码请求失败（\(status)）"
        case .notConfigured: "视频解码器尚未配置"
        case .queueFull: "视频解码队列已满"
        }
    }
}
