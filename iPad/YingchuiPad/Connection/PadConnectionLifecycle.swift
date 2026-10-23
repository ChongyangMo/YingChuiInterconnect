import CryptoKit
import Foundation
import Network
import Security
import UIKit
import YingchuiProtocol

extension PadConnectionModel {
    @MainActor
    func resumeAfterForeground() {
        isInBackgroundState.set(false)
        networkQueue.async { [weak self] in
            guard let self else { return }
            self.startBrowsingOnNetworkQueue()
            guard let endpoint = self.desiredEndpoint else { return }
            if self.connection != nil {
                self.startPingTimer()
                self.sendPingOnNetworkQueue()
                Task { @MainActor [weak self] in
                    guard let self, self.wantsStreaming, !self.isStreaming else { return }
                    self.startStreaming()
                }
                return
            }
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.publishStatus("已回到前台，正在恢复连接")
            self.connectOnNetworkQueue(to: endpoint)
        }
    }

    @MainActor
    func prepareForBackground() {
        isInBackgroundState.set(true)
        eventLog.record("应用进入后台，释放控制连接与回传，保留返回前台的恢复意图")
        videoReceiverGeneration.set(nil)
        videoRequestID.set(nil)
        isConnected = false
        isPaired = false
        isStreaming = false
        if wantsStreaming { streamStatusText = "已暂停，返回前台后自动恢复" }
        videoIsPlaying = false
        videoRenderer.reset()
        networkQueue.async { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            // 锁屏前关闭控制连接，不能只发 streamStop 后让占用残留到心跳超时。
            self.stopBrowsingOnNetworkQueue()
            self.usbService?.stop()
            self.disconnectOnNetworkQueue()
        }
    }

    @MainActor
    func connect(to host: DiscoveredHost) {
        enterFullScreenAfterConnection = false
        shouldPresentFullScreen = false
        let selection = UUID()
        connectionSelection.set(selection)
        connectionEpoch.set(selection)
        videoReceiverGeneration.set(nil)
        videoRequestID.set(nil)
        wantsStreaming = false
        isStreaming = false
        videoAspectRatio = nil
        videoIsPlaying = false
        videoRenderer.reset()
        connectedHostName = host.name
        statusText = "正在连接 \(host.name)"
        pairingMessage = "正在确认设备身份"
        isConnected = false
        isPaired = false
        roundTripMilliseconds = nil
        roundTripP95Milliseconds = nil
        roundTripSamples.reset()
        controlRoundTripMilliseconds = nil
        controlRoundTripP95Milliseconds = nil
        controlRoundTripSamples.reset()
        interactionToVideoFrameMilliseconds = nil
        interactionToVideoFrameP95Milliseconds = nil
        interactionToVideoFrameSamples.reset()
        latestInteractionToVideoFrameMilliseconds = nil
        connectedHostKey = host.hostID
        canResetCurrentHostTrust = false

        networkQueue.async { [weak self] in
            guard let self, self.connectionSelection.value == selection else { return }
            let hasSavedTrust = self.trustStore.credential(for: host.hostID) != nil || self.credentialStoreErrorText != nil
            Task { @MainActor [weak self] in
                guard let self, self.connectedHostKey == host.hostID else { return }
                self.canResetCurrentHostTrust = hasSavedTrust
            }
            self.desiredEndpoint = PeerNetworkTransport.reconnectEndpoint(host.endpoint)
            self.reconnectAttempt = 0
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.disconnectOnNetworkQueue()
            self.connectOnNetworkQueue(to: host.endpoint)
        }
    }

    @MainActor
    func disconnect() {
        enterFullScreenAfterConnection = false
        shouldPresentFullScreen = false
        let selection = UUID()
        connectionSelection.set(selection)
        connectionEpoch.set(selection)
        videoReceiverGeneration.set(nil)
        videoRequestID.set(nil)
        isConnected = false
        isPaired = false
        connectedHostName = nil
        connectedHostKey = nil
        canResetCurrentHostTrust = false
        roundTripMilliseconds = nil
        roundTripP95Milliseconds = nil
        roundTripSamples.reset()
        controlRoundTripMilliseconds = nil
        controlRoundTripP95Milliseconds = nil
        controlRoundTripSamples.reset()
        interactionToVideoFrameMilliseconds = nil
        interactionToVideoFrameP95Milliseconds = nil
        interactionToVideoFrameSamples.reset()
        latestInteractionToVideoFrameMilliseconds = nil
        pairingMessage = "连接后请输入 Mac 上显示的六位配对码"
        statusText = "连接已断开"
        isStreaming = false
        wantsStreaming = false
        streamStatusText = "屏幕回传已停止"
        videoResolutionText = "—"
        streamMetrics.reset()
        videoAspectRatio = nil
        videoIsPlaying = false
        videoRenderer.reset()
        estimatedVideoLatencyMilliseconds = nil
        latestVideoLatencyMilliseconds = nil
        videoLatencyP50Milliseconds = nil
        videoLatencyP95Milliseconds = nil
        videoLatencySamples.reset()
        networkQueue.async { [weak self] in
            guard let self, self.connectionSelection.value == selection else { return }
            self.desiredEndpoint = nil
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.disconnectOnNetworkQueue()
        }
    }

    func handleConnectionClosed(_ closedConnection: NWConnection, reason: String) {
        guard connection === closedConnection else { return }
        eventLog.record("控制连接断开：\(reason)")
        disconnectOnNetworkQueue()
        let epoch = connectionEpoch.value
        Task { @MainActor [weak self] in
            guard let self, self.connectionEpoch.value == epoch else { return }
            self.isConnected = false
            self.isPaired = false
            self.roundTripMilliseconds = nil
            self.roundTripP95Milliseconds = nil
            self.controlRoundTripMilliseconds = nil
            self.controlRoundTripP95Milliseconds = nil
            self.controlRoundTripSamples.reset()
            self.latestControlRoundTripState.set(nil)
            self.roundTripSamples.reset()
            self.interactionToVideoFrameMilliseconds = nil
            self.interactionToVideoFrameP95Milliseconds = nil
            self.interactionToVideoFrameSamples.reset()
            self.latestInteractionToVideoFrameMilliseconds = nil
            self.estimatedVideoLatencyMilliseconds = nil
            self.latestVideoLatencyMilliseconds = nil
            self.videoResolutionText = "—"
            self.streamMetrics.reset()
            self.videoAspectRatio = nil
            self.videoLatencyP50Milliseconds = nil
            self.videoLatencyP95Milliseconds = nil
            self.videoLatencySamples.reset()
            self.isStreaming = false
            self.videoIsPlaying = false
            self.videoRenderer.reset(preservingDisplayedImage: true)
            self.streamStatusText = "连接中断，等待恢复视频回传"
            self.statusText = reason
        }
        scheduleReconnectIfNeeded()
    }

    func scheduleReconnectIfNeeded() {
        guard !isInBackgroundState.value, desiredEndpoint != nil, connection == nil, reconnectWorkItem == nil else { return }
        let attempt = reconnectAttempt
        reconnectAttempt += 1
        let delay = min(8.0, pow(2.0, Double(min(attempt, 3))))
        publishStatus("连接中断，\(Int(delay)) 秒后自动重连")
        let epoch = connectionEpoch.value
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.connectionEpoch.value == epoch else { return }
            self.reconnectWorkItem = nil
            guard !self.isInBackgroundState.value, self.connection == nil, let endpoint = self.desiredEndpoint else { return }
            self.connectOnNetworkQueue(to: endpoint)
        }
        reconnectWorkItem = workItem
        networkQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}
