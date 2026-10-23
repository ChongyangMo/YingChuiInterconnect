import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import VideoToolbox
import YingchuiProtocol

extension MacScreenStreamer {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard self.stream === stream else { return }
        if outputType == .audio {
            guard capturesAudio, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
            do { try audioSender.send(sampleBuffer) }
            catch { stoppedHandler?("声音采集失败：\(error.localizedDescription)", .audio); stopOnCaptureQueue() }
            return
        }
        guard outputType == .screen else { return }
        guard sampleBuffer.isValid, compressionSession != nil else {
            videoProgress.recordCapture(status: "无效样本或编码器未就绪")
            return
        }

        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let frameStatus = SCFrameStatus(rawValue: rawStatus) else {
            videoProgress.recordCapture(status: "缺少帧状态")
            reportRuntimeError("屏幕采集帧缺少状态信息")
            return
        }
        let statusText: String
        switch frameStatus {
        case .complete: statusText = "完整画面"
        case .idle: statusText = "画面静止"
        case .blank: statusText = "显示器空白"
        case .suspended: statusText = "采集挂起"
        case .started: statusText = "采集开始"
        case .stopped: statusText = "采集停止"
        @unknown default: statusText = "未知状态 \(rawStatus)"
        }
        let captureNow = DispatchTime.now().uptimeNanoseconds
        receiverRequestedCaptureRefresh = false
        if let previous = videoProgress.lastCaptureUptime, captureNow >= previous,
           captureNow - previous >= 250_000_000, videoProgress.captureStatus == "完整画面" {
            eventLog.recordPeriodic(
                "屏幕采集回调间隔 \((captureNow - previous) / 1_000_000) 毫秒，恢复状态 \(statusText)，\(videoProgress.summary(now: captureNow))",
                key: "采集间隔", intervalNanoseconds: 2_000_000_000)
        }
        videoProgress.recordCapture(status: statusText, now: captureNow)
        guard frameStatus == .complete || frameStatus == .idle else { return }
        let age = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), sampleBuffer.presentationTimeStamp).seconds
#if DEBUG
        benchmarkMetrics.capture(idle: frameStatus == .idle, age: age,
                                 revision: captureRevision &+ (frameStatus == .complete ? 1 : 0))
#endif
        pipelineMetrics.capture(isIdle: frameStatus == .idle,
            ageNanoseconds: age.isFinite && age >= 0 && age < 60 ? UInt64(age * 1_000_000_000) : nil,
            now: captureNow)
        if frameStatus == .complete {
            guard CMSampleBufferDataIsReady(sampleBuffer), let image = sampleBuffer.imageBuffer else {
                reportRuntimeError("完整屏幕帧缺少像素数据")
                return
            }
            startupTrace?.mark("首个完整采集帧")
            applyCapturedColorMetadata(image)
            captureRecoveryPolicy.recordCapture(now: captureNow)
            startupImageProbe.inspect(image, trace: startupTrace)
            lastCaptureImage = image
            captureRevision &+= 1
            lastImageCaptureUptime = captureNow
#if DEBUG
            if investigation.settings != nil, !investigation.recordedCaptureColor {
                investigation.recordedCaptureColor = true
                eventLog.record("视频颜色调查：采集像素，\(VideoColorDiagnostics.describe(image))")
            }
#endif
        }
        // 仅在采集器实际报告 idle 时发送真实静止画面；采集回调中断时不伪造保活。
#if DEBUG
        // 对照组由独立定时器重复真实静止像素，变化帧仍立即进入原有链路。
        if frameStatus == .idle, benchmarkMetrics.settings?.idleFrameRate != nil { return }
#endif
        let keyFrameRequested = stateLock.withLock { forceNextKeyFrame }
        guard idleFramePolicy.shouldEncode(isIdle: frameStatus == .idle,
            hasImage: lastCaptureImage != nil, forceKeyFrame: keyFrameRequested),
            let pixelBuffer = lastCaptureImage else { return }

        let forceKeyFrame = stateLock.withLock {
            let value = forceNextKeyFrame
            forceNextKeyFrame = false
            return value
        }
        encodeCapturedImage(pixelBuffer, forceKeyFrame: forceKeyFrame)
    }

    func encodeCapturedImage(_ pixelBuffer: CVPixelBuffer, forceKeyFrame: Bool) {
        guard let compressionSession else { return }
        guard let ticket = encodeAdmission.admit(
            queuedPackets: stateLock.withLock { outstandingDatagrams },
            oldestQueuedAgeNanoseconds: datagramPacer.oldestQueuedAgeNanoseconds) else {
            if forceKeyFrame { stateLock.withLock { forceNextKeyFrame = true } }
            pipelineMetrics.preEncodeDrops += 1
            scheduleEncodeReplay()
            return
        }
        if captureRevision > submittedRevision { pipelineMetrics.newCaptureSubmissions += 1 }
        else { pipelineMetrics.repeatedSubmissions += 1 }
        submittedRevision = captureRevision
        pipelineMetrics.maximumPendingEncodes = max(pipelineMetrics.maximumPendingEncodes, encodeAdmission.pendingEncodes)
        videoProgress.submitted &+= 1
        let properties = forceKeyFrame
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        let captureWallClock = CMTime(
            value: Int64(Date().timeIntervalSince1970 * 1_000_000),
            timescale: 1_000_000
        )
        let generation = stateLock.withLock { captureGeneration }
        let frameContext = Unmanaged.passRetained(EncodedFrameContext(generation: generation, ticket: ticket))
#if DEBUG
        benchmarkLastSubmission = DispatchTime.now().uptimeNanoseconds
        benchmarkMetrics.submitted(source: UInt64(captureWallClock.value), revision: captureRevision,
                                   imageAge: Double(benchmarkLastSubmission - lastImageCaptureUptime) / 1_000_000)
#endif
        let status = VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: captureWallClock,
            duration: CMTime(value: 1, timescale: CMTimeScale(outputFrameRate)),
            frameProperties: properties,
            sourceFrameRefcon: frameContext.toOpaque(),
            infoFlagsOut: nil
        )
        if status != noErr {
            frameContext.release()
            encodeAdmission.complete(ticket)
            handleCompressionCallbackFailure(status: status, generation: generation)
        }
    }
}
