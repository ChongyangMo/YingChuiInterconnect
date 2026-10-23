import Foundation
import Network

/// 默认网络路径的提示信息，不能用于阻止附近设备发现或取消点对点连接。
public struct LocalNetworkState: Equatable, Sendable {
    public let isAvailable: Bool
    public let isWiFi: Bool

    public init(isAvailable: Bool, isWiFi: Bool) {
        self.isAvailable = isAvailable
        self.isWiFi = isWiFi
    }
}

public final class LocalNetworkPathObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var monitor: NWPathMonitor?

    public init() {}

    public func start(
        on queue: DispatchQueue,
        handler: @escaping @Sendable (LocalNetworkState) -> Void
    ) {
        stop()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            handler(
                LocalNetworkState(
                    isAvailable: path.status == .satisfied,
                    isWiFi: path.usesInterfaceType(.wifi)
                )
            )
        }
        lock.withLock {
            self.monitor = monitor
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        let activeMonitor = lock.withLock {
            let activeMonitor = monitor
            monitor = nil
            return activeMonitor
        }
        activeMonitor?.pathUpdateHandler = nil
        activeMonitor?.cancel()
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
