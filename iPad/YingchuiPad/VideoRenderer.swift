import AVFoundation
import CoreMedia
import SwiftUI
import UIKit
import YingchuiProtocol

@MainActor
final class VideoRenderer {
    let cursor = PadCursorModel()
    var startupTrace: StreamStartupTrace?
    var onNeedsKeyFrame: (() -> Void)?
    var onFrameDecoded: ((_ frameID: UInt32) -> Void)?
    var onFailure: ((String) -> Void)?
    private let frameDecoder = VideoFrameDecoder()
    private let presentationQueue = PadVideoPresentationQueue()
    private var lastDecodedFrameID: UInt32?
    let pipelineMetrics = PadVideoPipelineMetrics()
#if DEBUG
    var investigation = PadVideoInvestigationProbe()
#endif
    private var displayMetricsInFlight = false

    init() {
        presentationQueue.onQueueTiming = { [weak self] frame, queuedAt, deliveredAt, depth, immediateInteraction in
            guard let self else { return }
            self.pipelineMetrics.presentationWait.record(from: queuedAt, to: deliveredAt)
            self.pipelineMetrics.maximumPresentationDepth = max(self.pipelineMetrics.maximumPresentationDepth, depth)
#if DEBUG
            self.pipelineMetrics.benchmark.presentation(frame, queuedAt: queuedAt, deliveredAt: deliveredAt,
                depth: depth, immediateInteraction: immediateInteraction)
#endif
        }
        presentationQueue.onCoalesced = { [weak self] frame in
            self?.pipelineMetrics.coalesced += 1
#if DEBUG
            self?.pipelineMetrics.benchmark.frame("coalesced", frame)
#endif
        }
        presentationQueue.onClockGap = { [weak self] gap in
            self?.pipelineMetrics.presentationClockGap.record(gap)
#if DEBUG
            if PadVideoBenchmarkMetrics.enabled {
                self?.pipelineMetrics.benchmark.clockGap.record(milliseconds: Double(gap) / 1_000_000)
                self?.pipelineMetrics.benchmark.clock(gap)
            }
#endif
        }
        presentationQueue.onDisplay = { [weak self] image, frame in
            guard let self, self.streamID == frame.streamID else { return false }
            do { try self.display(image, frame: frame); return true }
            catch { self.onFailure?(error.localizedDescription); return false }
        }
        pipelineMetrics.onReport = { [weak self] in self?.reportDisplayPerformance() }
        frameDecoder.onTiming = { [weak self] frame, timing in
            guard let self else { return }
            self.pipelineMetrics.decode.record(from: timing.submittedAt, to: timing.callbackAt)
#if DEBUG
            if PadVideoBenchmarkMetrics.enabled {
                self.pipelineMetrics.benchmark.decode.record(from: timing.submittedAt, to: timing.callbackAt)
                self.pipelineMetrics.benchmark.decodeTiming(frame, timing: timing)
            }
#endif
            self.pipelineMetrics.decodeMainWait.record(from: timing.callbackAt, to: timing.deliveredAt)
            self.pipelineMetrics.maximumPending = max(self.pipelineMetrics.maximumPending, timing.pendingCount)
        }
        frameDecoder.onFrame = { [weak self] image, frame in
            guard let self, self.streamID == frame.streamID else { return }
            if let last = self.lastDecodedFrameID, Int32(bitPattern: frame.frameID &- last) <= 0 { return }
            self.lastDecodedFrameID = frame.frameID
            self.pipelineMetrics.decoded += 1
#if DEBUG
            self.pipelineMetrics.benchmark.frame("decoded", frame)
#endif
            if self.presentationQueue.submit(image, frame: frame) { self.onFrameDecoded?(frame.frameID) }
        }
        frameDecoder.onFailure = { [weak self] status in self?.onFailure?(status) }
    }

    private let displayLayers = NSHashTable<AVSampleBufferDisplayLayer>.weakObjects()
    private var formatDescription: CMVideoFormatDescription?
    private var streamID: UUID?
    private var lastFrameID: UInt32?
    private var requestedInitialKeyFrame = false
    // 只保留最近一个真实解码样本，供预览与全屏显示层交接。
    private var latestDisplaySample: CMSampleBuffer?

    func attach(_ layer: AVSampleBufferDisplayLayer, videoGravity: AVLayerVideoGravity) {
        layer.videoGravity = videoGravity
        layer.backgroundColor = UIColor.clear.cgColor
        layer.isOpaque = false
        guard !displayLayers.contains(layer) else { return }
        displayLayers.add(layer)
        if let latestDisplaySample {
            do {
                try enqueueDisplaySample(latestDisplaySample, on: layer)
                startupTrace?.mark("新显示层接续已有画面")
            } catch { onFailure?(error.localizedDescription) }
        }
    }

    func detach(_ layer: AVSampleBufferDisplayLayer) {
        displayLayers.remove(layer)
    }

    func prepareForInteraction() {
        guard streamID != nil else { return }
        presentationQueue.prepareForInteraction()
    }

    func configure(streamID: UUID, parameterSets: [Data], codec: VideoCodec = .h264) throws {
        let description = try VideoFormatDescriptionFactory.make(codec: codec, parameterSets: parameterSets)
        try frameDecoder.configure(description)
#if DEBUG
        investigation.configure(streamID: streamID, description: description, log: pipelineMetrics.log)
#endif
        latestDisplaySample = nil
        presentationQueue.reset()
        self.streamID = streamID
        lastDecodedFrameID = nil
        formatDescription = description
        lastFrameID = nil
        requestedInitialKeyFrame = false
        displayLayers.allObjects.forEach { $0.flush() }
    }

    func enqueue(_ frame: CompletedVideoFrame) throws {
        guard frame.streamID == streamID, let formatDescription else { return }
        let preparationStart = DispatchTime.now().uptimeNanoseconds
        defer { pipelineMetrics.prepare.record(from: preparationStart, to: DispatchTime.now().uptimeNanoseconds) }
#if DEBUG
        if lastFrameID == nil, !requestedInitialKeyFrame,
           ProcessInfo.processInfo.arguments.contains("--physical-smoke-test") {
            print("实机自动测试：首个解码输入为帧 \(frame.frameID)，关键帧 \(frame.isKeyFrame)，长度 \(frame.accessUnit.count) 字节")
        }
#endif
        // 接收链或主线程交付出现缺口时，后续 P 帧不能引用旧画面继续解码。
        if let lastFrameID, Int32(bitPattern: frame.frameID &- lastFrameID) > 1 {
            try frameDecoder.configure(formatDescription)
            self.lastFrameID = nil
            requestedInitialKeyFrame = false
        }
        guard lastFrameID != nil || frame.isKeyFrame else {
            if !requestedInitialKeyFrame {
                requestedInitialKeyFrame = true
                onNeedsKeyFrame?()
            }
            throw VideoRendererError.missingInitialKeyFrame
        }
        if let lastFrameID,
           Int32(bitPattern: frame.frameID &- lastFrameID) <= 0 {
            return
        }
        lastFrameID = frame.frameID

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: frame.accessUnit.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: frame.accessUnit.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw VideoRendererError.blockBuffer(status)
        }
        status = frame.accessUnit.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferReplaceDataBytes(
                with: source,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: frame.accessUnit.count
            )
        }
        guard status == kCMBlockBufferNoErr else { throw VideoRendererError.blockBuffer(status) }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(clamping: frame.presentationTimeMicroseconds), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = frame.accessUnit.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw VideoRendererError.sampleBuffer(status)
        }

        try frameDecoder.decode(sampleBuffer, frame: frame, preparationStartedAt: preparationStart)
    }

    private func display(_ image: CVPixelBuffer, frame: CompletedVideoFrame) throws {
#if DEBUG
        investigation.image(image, log: pipelineMetrics.log)
#endif
        let displayStart = DispatchTime.now().uptimeNanoseconds
        defer { pipelineMetrics.display.record(from: displayStart, to: DispatchTime.now().uptimeNanoseconds) }
        let sample = try VideoDisplaySampleFactory.make(image: image, sourceMicroseconds: frame.presentationTimeMicroseconds)
        latestDisplaySample = sample
        cursor.showVideo()
        for layer in displayLayers.allObjects { try enqueueDisplaySample(sample, on: layer) }
        pipelineMetrics.displayed(frame, at: DispatchTime.now().uptimeNanoseconds, layerCount: displayLayers.count)
    }

    private func enqueueDisplaySample(_ sample: CMSampleBuffer, on layer: AVSampleBufferDisplayLayer) throws {
        guard layer.status != .failed, !layer.requiresFlushToResumeDecoding else {
            throw VideoRendererError.displayFailed(layer.error?.localizedDescription ?? "显示层状态异常")
        }
        layer.enqueue(sample)
        if !layer.isReadyForMoreMediaData { pipelineMetrics.layersNotReady += 1 }
        startupTrace?.mark("首帧提交显示层")
    }

    func reset(preservingDisplayedImage: Bool = false) {
        cursor.reset()
        pipelineMetrics.reset()
        frameDecoder.reset()
        presentationQueue.reset()
        lastDecodedFrameID = nil
        streamID = nil
        formatDescription = nil
        lastFrameID = nil
        requestedInitialKeyFrame = false
        if !preservingDisplayedImage { latestDisplaySample = nil }
        startupTrace = nil
        displayLayers.allObjects.forEach {
            if preservingDisplayedImage { $0.flush() }
            else { $0.flushAndRemoveImage() }
        }
    }

    private func reportDisplayPerformance() {
        guard #available(iOS 17.4, *), !displayMetricsInFlight, let streamID else { return }
        let layers = displayLayers.allObjects
        displayMetricsInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.displayMetricsInFlight = false }
            for (index, layer) in layers.enumerated() {
                let metrics = await layer.sampleBufferRenderer.videoPerformanceMetrics
                guard self.streamID == streamID, self.displayLayers.contains(layer) else { return }
                guard let metrics else {
                    self.pipelineMetrics.log.record("系统显示统计：流 \(streamID)，显示层 \(index)，系统尚未提供统计")
                    continue
                }
                self.pipelineMetrics.log.record("系统显示统计：流 \(streamID)，显示层 \(index)，累计提交 \(metrics.totalNumberOfFrames)，累计丢弃 \(metrics.numberOfDroppedFrames)，损坏 \(metrics.numberOfCorruptedFrames)，直接合成 \(metrics.numberOfFramesDisplayedUsingOptimizedCompositing)，累计显示延误 \(String(format: "%.1f", metrics.totalAccumulatedFrameDelay * 1_000)) 毫秒")
            }
        }
    }

}

enum VideoRendererError: LocalizedError {
    case missingInitialKeyFrame
    case missingParameterSets
    case displayFailed(String)
    case formatDescription(OSStatus)
    case blockBuffer(OSStatus)
    case sampleBuffer(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingInitialKeyFrame:
            return "视频起始关键帧尚未收到，正在请求关键帧"
        case .displayFailed(let reason):
            return "视频显示失败：\(reason)"
        case .missingParameterSets:
            return "H.264 参数集不完整"
        case .formatDescription(let status):
            return "H.264 格式初始化失败（\(status)）"
        case .blockBuffer(let status):
            return "视频数据缓冲区错误（\(status)）"
        case .sampleBuffer(let status):
            return "视频帧创建失败（\(status)）"
        }
    }
}
