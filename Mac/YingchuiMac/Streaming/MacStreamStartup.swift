import Foundation
import Network
import YingchuiProtocol

extension MacScreenStreamer {
    func waitForTransports(generation: UUID) async throws {
        for attempt in 0..<150 {
            let ready = try captureQueue.sync {
                guard stateLock.withLock({ captureGeneration == generation }) else {
                    throw StreamerError.captureSuperseded
                }
                if mediaPacketSink != nil { return true }
                guard let video = udpConnection else { throw MacStreamStartupError.missingTransport }
                let videoReady = try Self.transportIsReady(video.state)
                let audioReady: Bool
                if capturesAudio {
                    guard let audio = audioSender.transportState else { throw MacStreamStartupError.missingTransport }
                    audioReady = try Self.transportIsReady(audio)
                } else { audioReady = true }
                return videoReady && audioReady
            }
            if ready {
                eventLog.record("音视频传输通道已就绪，开始屏幕采集")
                return
            }
            if attempt == 0 { eventLog.record("正在等待音视频传输通道就绪，暂不启动采集") }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw MacStreamStartupError.timeout
    }

    static func transportIsReady(_ state: NWConnection.State) throws -> Bool {
        switch state {
        case .ready: return true
        case .setup, .preparing, .waiting: return false
        case .failed(let error): throw error
        case .cancelled: throw MacStreamStartupError.cancelled
        @unknown default: throw MacStreamStartupError.missingTransport
        }
    }
}

enum MacStreamStartupError: LocalizedError {
    case missingTransport, timeout, cancelled
    var errorDescription: String? {
        switch self {
        case .missingTransport: "音视频传输通道未创建或状态无效"
        case .timeout: "音视频传输通道三秒内未就绪，请检查网络"
        case .cancelled: "音视频传输通道已取消"
        }
    }
}
