import Foundation
import YingchuiProtocol

struct PadAudioBufferTicket: Sendable {
    let generation: UUID
    let frames: Int
}

struct PadAudioBufferStatistics: Sendable {
    var bufferedFrames = 0
    var bufferedPackets = 0
    var renderedFrames: UInt64 = 0
    var peakBufferedFrames = 0
    var receivedFrames: UInt64 = 0
    var lastRenderedUptime: UInt64?
    var lastReceivedUptime: UInt64?
    var longestReceiveGapNanoseconds: UInt64 = 0
    var bufferedMilliseconds: Double { Double(bufferedFrames) * 1_000 / Double(AudioPacketCodec.sampleRate) }
}

/// 同时限制待调度与已调度的音频；容量按采样时长计，不把声卡输出延迟算成待播放积压。
final class PadAudioBufferBudget: @unchecked Sendable {
    static let maximumFrames = AudioBufferingPolicy.maximumBufferedFrames
    private struct State: Sendable {
        var generation = UUID()
        var failed = false
        var statistics = PadAudioBufferStatistics()
    }
    private let state = SynchronizedValue(State())
    var generation: UUID { state.value.generation }
    var statistics: PadAudioBufferStatistics { state.value.statistics }

    func reserve(frames: Int, generation: UUID) throws -> PadAudioBufferTicket {
        try state.mutate { state -> Result<PadAudioBufferTicket, PadAudioPlaybackError> in
            guard state.generation == generation, !state.failed else { return .failure(.stopped) }
            guard (1...AudioPacketCodec.maximumFrames).contains(frames) else { return .failure(.invalidFrames) }
            guard state.statistics.bufferedFrames + frames <= Self.maximumFrames else {
                return .failure(.backlogExceeded(state.statistics.bufferedFrames))
            }
            guard state.statistics.bufferedPackets < 512 else { return .failure(.tooManyFragments) }
            state.statistics.bufferedFrames += frames
            state.statistics.bufferedPackets += 1
            let now = DispatchTime.now().uptimeNanoseconds
            if let previous = state.statistics.lastReceivedUptime, now >= previous {
                state.statistics.longestReceiveGapNanoseconds = max(state.statistics.longestReceiveGapNanoseconds, now - previous)
            }
            state.statistics.lastReceivedUptime = now
            state.statistics.receivedFrames += UInt64(frames)
            state.statistics.peakBufferedFrames = max(state.statistics.peakBufferedFrames, state.statistics.bufferedFrames)
            return .success(PadAudioBufferTicket(generation: generation, frames: frames))
        }.get()
    }

    /// 在音频渲染回调中立即归还容量，不排到网络突发数据之后。
    func rendered(_ ticket: PadAudioBufferTicket) -> Bool {
        state.mutate { state in
            guard state.generation == ticket.generation, !state.failed else { return false }
            state.statistics.bufferedFrames -= ticket.frames
            state.statistics.bufferedPackets -= 1
            state.statistics.renderedFrames += UInt64(ticket.frames)
            state.statistics.lastRenderedUptime = DispatchTime.now().uptimeNanoseconds
            return true
        }
    }

    func isActive(_ generation: UUID) -> Bool {
        let value = state.value
        return value.generation == generation && !value.failed
    }

    func isFailed(_ generation: UUID) -> Bool {
        let value = state.value
        return value.generation == generation && value.failed
    }

    func fail(_ generation: UUID) -> Bool {
        state.mutate { state in
            guard state.generation == generation, !state.failed else { return false }
            state.failed = true
            return true
        }
    }

    func reset() { state.set(State()) }

}

enum PadAudioPlaybackError: LocalizedError {
    case stopped, engineStopped, invalidFrames, tooManyFragments, backlogExceeded(Int)
    var errorDescription: String? {
        switch self {
        case .stopped: "声音播放已停止"
        case .engineStopped: "声音播放引擎被系统停止，已停止回传，请重新连接"
        case .invalidFrames: "声音采样帧数无效"
        case .tooManyFragments: "声音分片积压超过 512 个缓冲上限，已停止回传"
        case .backlogExceeded(let frames):
            "声音持续积压超出缓冲上限（当前 \(frames * 1_000 / AudioPacketCodec.sampleRate) 毫秒，上限 \(AudioBufferingPolicy.maximumBufferedMilliseconds) 毫秒），已停止回传"
        }
    }
}
