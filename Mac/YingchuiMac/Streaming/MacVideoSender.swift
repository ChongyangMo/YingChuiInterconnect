import AVFoundation
import CoreMedia
import Foundation
import Network
import ScreenCaptureKit
import VideoToolbox
import YingchuiProtocol

extension MacScreenStreamer {
    func handleEncodedSample(_ sampleBuffer: CMSampleBuffer, generation: UUID) {
        guard stateLock.withLock({ captureGeneration == generation }) else { return }
#if DEBUG
        if videoCodec == .hevc, let settings = investigation.settings,
           framesEncoded >= UInt64(settings.afterFrames ?? 60), settings.consume(.hevcRuntime) {
            eventLog.record("故障注入验证：主动停止持续 HEVC 输出，观察接收端改用 H.264")
            stoppedHandler?("故障注入验证：HEVC 输出已主动停止", .codec)
            stopOnCaptureQueue()
            return
        }
        if investigation.settings != nil, !investigation.recordedEncodedColor,
           let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            investigation.recordedEncodedColor = true
            eventLog.record("视频颜色调查：编码输出，\(VideoColorDiagnostics.describe(format))")
        }
#endif
        videoProgress.recordEncoded()
        guard stream != nil,
              compressionSession != nil,
              (udpConnection != nil || mediaPacketSink != nil),
              CMSampleBufferDataIsReady(sampleBuffer),
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            recordDroppedFrame()
            return
        }

        let isKeyFrame = !(CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            .flatMap { unsafeBitCast(CFArrayGetValueAtIndex($0, 0), to: CFDictionary.self) }
            .map { CFDictionaryContainsKey($0, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()) }
            ?? false)

        if isKeyFrame,
           let format = CMSampleBufferGetFormatDescription(sampleBuffer),
           let parameterSets = extractParameterSets(from: format),
           parameterSets != lastParameterSets {
            lastParameterSets = parameterSets
            configurationHandler?(
                EncodedVideoConfiguration(
                    streamID: streamID,
                    codec: videoCodec,
                    width: outputWidth,
                    height: outputHeight,
                    frameRate: outputFrameRate,
                    bitRate: outputBitRate,
                    parameterSets: parameterSets,
                    videoKey: videoKey
                )
            )
        }

        let length = CMBlockBufferGetDataLength(dataBuffer)
        let packetizeStart = DispatchTime.now().uptimeNanoseconds
        pipelineMetrics.encoded += 1
        pipelineMetrics.encodedBytes += length
        pipelineMetrics.maximumFrameBytes = max(pipelineMetrics.maximumFrameBytes, length)
        startupTrace?.mark("首个编码输出", detail: "关键帧 \(isKeyFrame)，长度 \(length) 字节")
        var accessUnit = Data(count: length)
        let copyStatus = accessUnit.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
            return CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: baseAddress)
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            recordDroppedFrame()
            reportRuntimeError("编码数据读取失败（\(copyStatus)）")
            return
        }

        let presentationTime = sampleBuffer.presentationTimeStamp
        let microseconds = presentationTime.isValid
            ? UInt64(max(0, CMTimeGetSeconds(presentationTime) * 1_000_000))
            : 0
        let currentFrameID = frameID
        frameID &+= 1

        do {
            let datagrams = try VideoDatagramCodec.fragment(
                accessUnit: accessUnit,
                streamID: streamID,
                frameID: currentFrameID,
                presentationTimeMicroseconds: microseconds,
                isKeyFrame: isKeyFrame
            )
            let copiesPerFragment = mediaPacketSink != nil ? 1 : VideoPacketReplicationPolicy.copiesPerFragment(
                isKeyFrame: isKeyFrame,
                fragmentCount: datagrams.count
            )
#if DEBUG
            benchmarkMetrics.encoded(id: currentFrameID, source: microseconds, keyFrame: isKeyFrame,
                                     bytes: length, packets: datagrams.count, copies: copiesPerFragment)
#endif
            if isKeyFrame {
                videoProgress.lastKeyFrameDescription = "最近关键帧 \(currentFrameID)，\(length) 字节，\(datagrams.count) 个分片"
            }
            let sealedDatagrams = try datagrams.map { try VideoDatagramCrypto.seal($0, key: videoKey) }
            pipelineMetrics.packetize.record(from: packetizeStart, to: DispatchTime.now().uptimeNanoseconds)
            let connection = udpConnection
            guard shouldSend(datagramCount: datagrams.count * copiesPerFragment) else {
                recordDroppedFrame()
                pipelineMetrics.sendDrops += 1
                stateLock.withLock { forceNextKeyFrame = true }
                return
            }
            repairCache.store(frameID: currentFrameID, packets: sealedDatagrams)
            // 初次 UDP 流建立期间，紧邻的两份副本可能一起丢失。
            // 仅将首帧已有的第二份副本错开 50 毫秒，总包数与稳态发送策略不变。
            let separatedStartupReplica = currentFrameID == 0 && copiesPerFragment == 2
            sendDatagrams(sealedDatagrams, copies: separatedStartupReplica ? 1 : copiesPerFragment,
                          connection: connection, generation: generation, frameID: currentFrameID)
            if separatedStartupReplica {
                captureQueue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                    guard let self, self.udpConnection === connection,
                          self.stateLock.withLock({ self.captureGeneration == generation }) else { return }
                    self.sendDatagrams(sealedDatagrams, copies: 1, connection: connection, generation: generation, frameID: currentFrameID)
                    self.startupTrace?.mark("首帧错峰副本已发送")
                }
            }
            startupTrace?.mark("首帧提交网络发送", detail: "分片 \(datagrams.count) 个")
            framesEncoded &+= 1
            if framesEncoded.isMultiple(of: UInt64(max(1, outputFrameRate))) {
                statisticsHandler?(framesEncoded, framesDropped)
            }
        } catch {
            recordDroppedFrame()
            reportRuntimeError("视频分片加密失败：\(error.localizedDescription)")
        }
    }

    func sendDatagrams(_ datagrams: [Data], copies: Int,
                       connection: NWConnection?, generation: UUID, priority: Bool = false, frameID: UInt32? = nil) {
        if let sink = mediaPacketSink {
            for _ in 0..<copies {
                for datagram in datagrams {
                    sink(.video, datagram) { [weak self] error in
                        self?.captureQueue.async { [weak self] in self?.didCompleteDatagram(error: error, generation: generation) }
                    }
                }
            }
            return
        }
        guard let connection else { return }
        // 分批匀速提交；关键帧先发完第一份，再发副本，避免两份一起落在同一无线突发里。
        let send: ([Data]) -> Void = { [weak self, weak connection] batch in
            guard let self, let connection, self.udpConnection === connection,
                  self.stateLock.withLock({ self.captureGeneration == generation }) else { return }
            connection.batch {
                let submittedAt = DispatchTime.now().uptimeNanoseconds
                for (index, datagram) in batch.enumerated() {
                    connection.send(content: datagram, completion: .contentProcessed { [weak self] error in
                        self?.didCompleteDatagram(error: error, generation: generation)
                        if index == batch.count - 1, let self,
                           self.stateLock.withLock({ self.captureGeneration == generation }) {
                            self.pipelineMetrics.networkSubmit.record(from: submittedAt, to: DispatchTime.now().uptimeNanoseconds)
                        }
                    })
                }
            }
        }
        if usesWirelessVideo {
            datagramPacer.enqueue(datagrams, copies: copies, priority: priority, onTiming: { [weak self] wait, drain in
                guard let self, self.stateLock.withLock({ self.captureGeneration == generation }) else { return }
                self.pipelineMetrics.pacingWait.record(wait)
                self.pipelineMetrics.pacingDrain.record(drain)
#if DEBUG
                if let frameID { self.benchmarkMetrics.sent(id: frameID, wait: wait, drain: drain) }
#endif
            }, send: send)
        } else {
            for _ in 0..<copies { send(datagrams) }
        }
    }

    func shouldSend(datagramCount: Int) -> Bool {
        stateLock.withLock {
            guard (udpConnection != nil || mediaPacketSink != nil), outstandingDatagrams + datagramCount <= 1_024 else { return false }
            outstandingDatagrams += datagramCount
            pipelineMetrics.maximumQueuedPackets = max(pipelineMetrics.maximumQueuedPackets, outstandingDatagrams)
            return true
        }
    }

    func didCompleteDatagram(error: NWError?, generation: UUID) {
        let isCurrent = stateLock.withLock {
            guard captureGeneration == generation else { return false }
            outstandingDatagrams = max(0, outstandingDatagrams - 1)
            return true
        }
        if isCurrent, let error {
            reportRuntimeError("视频数据发送失败：\(error.localizedDescription)")
        }
    }

    func recordDroppedFrame() {
        framesDropped &+= 1
        if framesDropped.isMultiple(of: 30) {
            statisticsHandler?(framesEncoded, framesDropped)
        }
    }

    func reportRuntimeError(_ message: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastRuntimeErrorReportUptime >= 2_000_000_000 else { return }
        lastRuntimeErrorReportUptime = now
        statusHandler?(message)
    }
}
