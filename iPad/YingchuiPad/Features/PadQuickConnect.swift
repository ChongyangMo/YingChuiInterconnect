import Foundation
import YingchuiProtocol

extension PadConnectionModel {
    @MainActor
    func quickConnect() {
        guard let lastHostID,
              let host = discoveredHosts.first(where: { $0.hostID == lastHostID }) else {
            discoveryStatus = "上次的 Mac 不在线，请检查 Mac 和局域网"
            return
        }
        connect(to: host)
        enterFullScreenAfterConnection = true
    }

    @MainActor
    func rememberConnectedHost() {
        guard let connectedHostKey, let connectedHostName else { return }
        lastHostID = connectedHostKey
        lastHostName = connectedHostName
        UserDefaults.standard.set(connectedHostKey, forKey: "YingchuiLastHostID")
        UserDefaults.standard.set(connectedHostName, forKey: "YingchuiLastHostName")
        if enterFullScreenAfterConnection { wantsStreaming = true }
    }

    @MainActor
    func retryPlayback() {
        if isConnected && isPaired {
            stopStreaming()
            startStreaming()
            return
        }
        guard let hostID = connectedHostKey,
              let host = discoveredHosts.first(where: { $0.hostID == hostID }) else {
            streamStatusText = "Mac 不在线，请检查 Mac 和局域网"
            return
        }
        connect(to: host)
        enterFullScreenAfterConnection = true
    }

    @MainActor
    func selectQuality(_ quality: StreamQualityPreset) {
        selectedQuality = quality
        if wantsStreaming {
            scheduleStreamReconfiguration(quality: quality, status: "正在切换画质")
        }
    }
}
