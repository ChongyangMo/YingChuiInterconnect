import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox
import YingchuiProtocol

extension MacScreenStreamer {
    func createNegotiatedCompressionSession() throws {
        do {
#if DEBUG
            if videoCodec == .hevc, investigation.settings?.consume(.hevcStartup) == true {
                eventLog.record("故障注入验证：主动拒绝本次 HEVC 启动，观察已协商的 H.264 回退")
                throw StreamerError.compressionSession(-1)
            }
#endif
            try createCompressionSession()
        }
        catch {
            guard videoCodec == .hevc, let fallback = h264FallbackFrameRate else { throw error }
            eventLog.record("HEVC 编码器启动失败，按已协商能力回退 H.264：\(error.localizedDescription)")
            videoCodec = .h264
            outputFrameRate = fallback
            try createCompressionSession()
        }
    }

    func createCompressionSession() throws {
        var lowLatency = MacVideoEncoderPolicy.lowLatencyRateControl
#if DEBUG
        lowLatency = benchmarkMetrics.settings?.lowLatencyRateControl ?? lowLatency
#endif
        let created: VTCompressionSession
        do { created = try makeCompressionSession(lowLatency: lowLatency) }
        catch {
            guard lowLatency else { throw error }
            eventLog.record("硬件编码器不接受低延迟规格，保留硬件要求重新创建：\(error.localizedDescription)")
            lowLatency = false
            created = try makeCompressionSession(lowLatency: false)
        }
        do {
            try configureCompressionSession(created)
            let status = VTCompressionSessionPrepareToEncodeFrames(created)
            guard status == noErr else { throw StreamerError.compressionSession(status) }
        } catch {
            VTCompressionSessionInvalidate(created)
            throw error
        }
        compressionSession = created
#if DEBUG
        benchmarkMetrics.actualLowLatencyRateControl = lowLatency
#endif
        consecutiveEncoderFailures = 0
        eventLog.record("\(videoCodec.title) 硬件编码器已就绪：\(outputWidth)×\(outputHeight)，\(outputFrameRate) 帧/秒，低延迟速率控制\(lowLatency ? "启用" : "未启用")")
    }

    private func makeCompressionSession(lowLatency: Bool) throws -> VTCompressionSession {
        var created: VTCompressionSession?
        var specification: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        if lowLatency { specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
            width: Int32(outputWidth), height: Int32(outputHeight),
            codecType: videoCodec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary, imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { ownerPointer, framePointer, status, flags, sample in
                guard let framePointer else { return }
                let context = Unmanaged<EncodedFrameContext>.fromOpaque(framePointer).takeRetainedValue()
                guard let ownerPointer else { return }
                let owner = Unmanaged<MacScreenStreamer>.fromOpaque(ownerPointer).takeUnretainedValue()
                let callbackAt = DispatchTime.now().uptimeNanoseconds
                let transferred = sample.map { SendableSampleBuffer(value: $0, generation: context.generation) }
                owner.captureQueue.async {
                    guard owner.stateLock.withLock({ owner.captureGeneration == context.generation }) else { return }
                    defer { owner.finishEncode(context.ticket) }
                    owner.pipelineMetrics.encode.record(from: context.submittedAt, to: callbackAt)
#if DEBUG
                    if owner.benchmarkMetrics.settings != nil {
                        owner.benchmarkMetrics.encode.record(from: context.submittedAt, to: callbackAt)
                    }
#endif
                    owner.pipelineMetrics.callbackQueue.record(from: callbackAt, to: DispatchTime.now().uptimeNanoseconds)
                    guard status == noErr else {
                        owner.handleCompressionCallbackFailure(status: status, generation: context.generation)
                        return
                    }
                    if flags.contains(.frameDropped) {
                        owner.handleEncoderDroppedFrame(generation: context.generation)
                        return
                    }
                    guard let transferred else {
                        owner.handleCompressionCallbackFailure(status: nil, generation: context.generation)
                        return
                    }
                    owner.consecutiveEncoderFailures = 0
                    owner.handleEncodedSample(transferred.value, generation: transferred.generation)
                }
            }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &created)
        guard status == noErr, let created else {
            if let created { VTCompressionSessionInvalidate(created) }
            throw StreamerError.compressionSession(status)
        }
        return created
    }

    func configureCompressionSession(_ session: VTCompressionSession) throws {
        try setCompressionProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        try setCompressionProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        try setCompressionProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
            value: videoCodec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        try setCompressionProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: outputBitRate as CFNumber)
        try setCompressionProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: outputFrameRate as CFNumber)
        let delayStatus = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        if delayStatus != noErr { eventLog.record("编码器不支持零帧等待，保留实时与无重排设置：\(delayStatus)") }
        // 避免默认 GOP 反复制造突发；真实丢帧和首帧仍显式请求关键帧。
        try setCompressionProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 3_600 as CFNumber)
        try setCompressionProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 60 as CFNumber)
    }

    func setCompressionProperty(_ session: VTCompressionSession, key: CFString, value: CFTypeRef) throws {
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else { throw StreamerError.compressionProperty(key as String, status) }
    }

    func handleCompressionCallbackFailure(status: OSStatus?, generation: UUID) {
        guard stateLock.withLock({ captureGeneration == generation }), compressionSession != nil else { return }
        recordDroppedFrame()
        consecutiveEncoderFailures += 1
        stateLock.withLock { forceNextKeyFrame = true }
        let detail = status.map { "错误码 \($0)" } ?? "没有返回视频帧"
        reportRuntimeError("\(videoCodec.title) 编码失败：\(detail)")
        if videoCodec == .hevc, consecutiveEncoderFailures >= 8 {
            stoppedHandler?("HEVC 编码连续失败，重新协商 H.264", .codec)
            stopOnCaptureQueue()
        }
    }

    func handleEncoderDroppedFrame(generation: UUID) {
        guard stateLock.withLock({ captureGeneration == generation }), compressionSession != nil else { return }
        videoProgress.encoderDropped &+= 1
        pipelineMetrics.encoderDrops += 1
        recordDroppedFrame()
        if videoCodec == .hevc {
            consecutiveEncoderFailures += 1
            if consecutiveEncoderFailures >= 30 {
                stoppedHandler?("HEVC 编码器连续丢弃输入，重新协商 H.264", .codec)
                stopOnCaptureQueue()
                return
            }
        }
        eventLog.recordPeriodic("编码器码率调节丢帧：累计 \(videoProgress.encoderDropped) 帧，当前码率 \(outputBitRate) bps",
            key: "编码器码率丢帧", intervalNanoseconds: 5_000_000_000)
    }
}
