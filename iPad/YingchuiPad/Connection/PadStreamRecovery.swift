import CryptoKit
import Foundation
import Network
import Security
import UIKit
import YingchuiProtocol

extension PadConnectionModel {
    @MainActor
    func handleVideoStatistics(_ snapshot: PadVideoReceiveSnapshot,
                               now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        guard wantsStreaming, isStreaming, !videoConfigurationPending,
              videoReceiverGeneration.value == snapshot.generation,
              activeStreamID == snapshot.streamID,
              now >= snapshot.uptimeNanoseconds,
              now - snapshot.uptimeNanoseconds <= 2_000_000_000,
              lastVideoStatisticsUptime.map({ snapshot.uptimeNanoseconds > $0 }) ?? true else { return }
        lastVideoStatisticsUptime = snapshot.uptimeNanoseconds
        // 在主线程实际处理时读取最新解码计数，避免使用排队前的旧解码快照。
        let playback = playbackStatistics.snapshot()
        let completed = playback.decodedFrames
        let dropped = snapshot.dropped &+ playback.droppedFrames
        videoPacketsReceived = snapshot.packets
        videoFramesDecoded = completed
        videoFramesDropped = dropped
        estimatedVideoLatencyMilliseconds = latestVideoLatencyMilliseconds
        videoLatencyP50Milliseconds = videoLatencySamples.percentile(0.50)
        videoLatencyP95Milliseconds = videoLatencySamples.percentile(0.95)
        if let latestInteractionToVideoFrameMilliseconds {
            interactionToVideoFrameMilliseconds = latestInteractionToVideoFrameMilliseconds
            interactionToVideoFrameSamples.append(latestInteractionToVideoFrameMilliseconds)
            self.latestInteractionToVideoFrameMilliseconds = nil
        }
        interactionToVideoFrameP95Milliseconds = interactionToVideoFrameSamples.percentile(0.95)

        func delta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
            current >= previous ? current - previous : current
        }
        let completedDelta = previousStatistics.map { delta(completed, $0.completed) } ?? 0
        let packetDelta = previousStatistics.map { delta(snapshot.packets, $0.packets) } ?? 0
        let assembledDelta = previousStatistics.map { delta(snapshot.assembled, $0.assembled) } ?? 0
        previousStatistics = (snapshot.packets, snapshot.assembled, completed, dropped)
        let audio = audioReceiver.playbackStatistics
        streamMetrics.sample(streamID: snapshot.streamID, decodedFrames: completed,
            audioMilliseconds: isAudioEnabled ? audio.bufferedMilliseconds : nil, now: now)
        eventLog.recordPeriodic(
            "回传统计：流 \(snapshot.streamID)，累计解码 \(completed) 帧，本周期新增 \(completedDelta) 帧，组帧新增 \(assembledDelta) 帧，收包新增 \(packetDelta) 个，累计丢帧 \(dropped)，网络缺帧 \(snapshot.networkMissing.map(String.init) ?? "未提供")，声音待播放 \(Int(audio.bufferedMilliseconds)) 毫秒",
            key: "播放统计", intervalNanoseconds: 10_000_000_000)

        let action = videoStallPolicy.evaluate(now: now)
        let evidence = "流 \(snapshot.streamID)，本周期收包 \(packetDelta)，组帧 \(assembledDelta)，解码 \(completedDelta)"
        if action == .requestKeyFrame {
            eventLog.record("视频解码已停滞至少 2 秒，请求关键帧：\(evidence)")
            requestKeyFrame()
        }
        networkQueue.async { [weak self] in
            guard let self, self.wantsStreaming, !self.videoConfigurationPending,
                  self.videoReceiverGeneration.value == snapshot.generation,
                  self.activeStreamID == snapshot.streamID,
                  let connection = self.connection else { return }
            self.send(WireMessage(kind: .streamStats, streamID: snapshot.streamID,
                packetsReceived: snapshot.packets, framesDecoded: completed, framesDropped: dropped,
                networkFramesMissing: snapshot.networkMissing),
                over: connection)
            if completedDelta > 0 { self.streamRecoveryPolicy.recordHealthyInterval() }
            else { self.streamRecoveryPolicy.recordStalledInterval() }
            if action == .recover, self.playbackStatistics.snapshot().decodedFrames == completed {
                if assembledDelta > 0 { self.disableHEVC(reason: "完整视频帧已收到但没有解码进展") }
                self.scheduleStreamRecoveryAfterFailure(reason: "连续至少 4 秒没有实际解码输出；\(evidence)")
            }
        }
    }

    func scheduleStreamRecoveryAfterFailure(reason: String) {
        guard wantsStreaming, streamRecoveryWorkItem == nil else { return }
        eventLog.record("视频流恢复开始：原因 \(reason)，流 \(activeStreamID?.uuidString ?? "尚未配置")；控制连接\(connection == nil ? "已断开" : "仍在线")")
        videoReceiverGeneration.set(nil)
        videoRequestID.set(nil)
        videoConfigurationDeadline?.cancel()
        videoConfigurationDeadline = nil
        requestedDisplayConfiguration = nil
        videoConfigurationPending = false
        if let connection {
            send(WireMessage(kind: .streamStop), over: connection)
        }
        activeStreamID = nil
        activeVideoPort = nil
        audioReceiver.stop()
        activeAudioPort = nil
        videoReceiver.stop()
        streamRecoveryWorkItem?.cancel()

        guard wantsStreaming, connection != nil else { return }
        guard let delay = streamRecoveryPolicy.nextDelaySeconds() else {
            eventLog.record("视频流恢复失败：已达到连续重试上限")
            wantsStreaming = false
            Task { @MainActor [weak self] in
                guard let self, !self.wantsStreaming else { return }
                self.activeDisplayState = nil
                self.displayModeChanging = false
                self.isStreaming = false
                self.streamMetrics.reset()
                self.videoIsPlaying = false
                self.videoRenderer.reset()
                self.streamStatusText = "屏幕回传连续启动失败，请检查 Mac 状态后重试"
                self.statusText = self.streamStatusText
            }
            return
        }

        let epoch = connectionEpoch.value
        eventLog.record("视频流将在 \(delay) 秒后重建接收端")
        Task { @MainActor [weak self] in
            guard let self, self.connectionEpoch.value == epoch, self.wantsStreaming else { return }
            self.isStreaming = false
            self.streamMetrics.reset()
            self.videoIsPlaying = false
            self.videoRenderer.reset(preservingDisplayedImage: true)
            self.streamStatusText = "Mac 屏幕回传已停止，\(delay) 秒后自动重试"
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.streamRecoveryWorkItem = nil
            guard self.wantsStreaming, self.connection != nil else { return }
            Task { @MainActor [weak self] in
                guard let self, self.wantsStreaming, self.connectionEpoch.value == epoch else { return }
                self.isStreaming = true
                self.streamStatusText = "正在重建视频接收端"
                self.startVideoReceiver()
            }
        }
        streamRecoveryWorkItem = workItem
        networkQueue.asyncAfter(deadline: .now() + .seconds(delay), execute: workItem)
    }
}
