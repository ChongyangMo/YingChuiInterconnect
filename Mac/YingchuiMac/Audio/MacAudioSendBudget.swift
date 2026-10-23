import Foundation
import YingchuiProtocol

/// 网络完成回调可直接归还容量，不必等屏幕采集队列处理完下一批数据。
final class MacAudioSendBudget: @unchecked Sendable {
    static let maximumFrames = AudioBufferingPolicy.maximumBufferedFrames
    private struct State: Sendable {
        var generation = UUID()
        var pendingFrames = 0
        var failed = false
    }
    private let state = SynchronizedValue(State())
    var generation: UUID { state.value.generation }
    var pendingFrames: Int { state.value.pendingFrames }

    func reserve(frames: Int) throws -> UUID {
        try state.mutate { value -> Result<UUID, MacAudioSendError> in
            guard !value.failed else { return .failure(.stopped) }
            guard frames > 0, frames <= Self.maximumFrames - value.pendingFrames else {
                return .failure(.backlogExceeded(pending: value.pendingFrames, incoming: frames))
            }
            value.pendingFrames += frames
            return .success(value.generation)
        }.get()
    }

    func complete(frames: Int, generation: UUID) -> Bool {
        state.mutate { value in
            guard value.generation == generation, !value.failed else { return false }
            value.pendingFrames -= frames
            return true
        }
    }

    func fail(_ generation: UUID) -> Bool {
        state.mutate { value in
            guard value.generation == generation, !value.failed else { return false }
            value.failed = true
            return true
        }
    }

    func isFailed(_ generation: UUID) -> Bool {
        let value = state.value
        return value.generation == generation && value.failed
    }
    func reset() { state.set(State()) }
}

enum MacAudioSendError: LocalizedError {
    case stopped
    case backlogExceeded(pending: Int, incoming: Int)
    var errorDescription: String? {
        switch self {
        case .stopped: "声音发送已经停止"
        case let .backlogExceeded(pending, incoming):
            "待发送声音超过 \(AudioBufferingPolicy.maximumBufferedMilliseconds) 毫秒缓冲上限：已排队 \(pending) 采样帧，本批 \(incoming) 采样帧，已停止回传"
        }
    }
}
