import Foundation
import YingchuiProtocol

extension PadConnectionModel {
    @MainActor
    func setAudioEnabled(_ enabled: Bool) {
        guard enabled != isAudioEnabled else { return }
        isAudioEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "YingchuiAudioEnabled")
        if wantsStreaming { stopStreaming(); startStreaming() }
    }

    func sendStreamWhenPortsReady() {
        guard wantsStreaming, let videoPort = activeVideoPort, let connection else { return }
        guard !audioRequested.value || activeAudioPort != nil else { return }
        sendStreamRequest(streamRequest, port: videoPort, over: connection)
    }
}
