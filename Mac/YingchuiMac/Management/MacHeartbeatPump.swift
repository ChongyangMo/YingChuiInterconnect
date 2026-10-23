import Foundation

/// 状态变化合并为最新一次回报；上一条请求未结束时不并行发送。
@MainActor
final class MacHeartbeatPump {
    private var continuation: AsyncStream<Void>.Continuation?
    private var consumer: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func start(interval: Duration = .seconds(300), debounce: Duration = .milliseconds(250),
               operation: @escaping () async throws -> Void, onError: @escaping (Error) -> Void) {
        stop()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        consumer = Task {
            for await _ in stream {
                do {
                    try await Task.sleep(for: debounce)
                    try Task.checkCancellation()
                    try await operation()
                } catch is CancellationError { return }
                catch { onError(error) }
            }
        }
        timer = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                continuation.yield()
            }
        }
        request()
    }
    func request() { continuation?.yield() }
    func stop() {
        continuation?.finish()
        continuation = nil
        consumer?.cancel()
        consumer = nil
        timer?.cancel()
        timer = nil
    }
}
