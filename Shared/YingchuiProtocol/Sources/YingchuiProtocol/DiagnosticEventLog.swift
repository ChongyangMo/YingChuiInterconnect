import Foundation
import OSLog

public final class DiagnosticEventLog: @unchecked Sendable {
    private struct Entry: Sendable {
        let date: Date
        let message: String
    }

    private let logger: Logger
    private let category: String
    private let capacity: Int
    private let lock = NSLock()
    private let mirrorsToTestConsole: Bool = {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--physical-smoke-test")
            || ProcessInfo.processInfo.arguments.contains("--diagnostic-console")
#else
        false
#endif
    }()
    private var entries: [Entry] = []
    private var lastMessages: [String: String] = [:]
    private var lastEmission: [String: UInt64] = [:]

    public func recordPeriodic(_ message: String, key: String, intervalNanoseconds: UInt64,
                               now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.lock()
        if let previous = lastEmission[key], now >= previous, now - previous < intervalNanoseconds {
            lock.unlock()
            return
        }
        if lastEmission[key] == nil, lastEmission.count >= capacity { lastEmission.removeAll() }
        lastEmission[key] = now
        lock.unlock()
        record(message)
    }

    /// 只用于状态快照；错误仍调用 record，不能去重隐藏错误。
    public func recordChange(_ message: String, key: String) {
        lock.lock()
        guard lastMessages[key] != message else { lock.unlock(); return }
        if lastMessages[key] == nil, lastMessages.count >= capacity { lastMessages.removeAll() }
        lastMessages[key] = message
        lock.unlock()
        record(message)
    }

    public init(subsystem: String, category: String, capacity: Int = 100) {
        logger = Logger(subsystem: subsystem, category: category)
        self.category = category
        self.capacity = max(1, capacity)
    }

    public func record(_ message: String) {
        logger.info("\(message, privacy: .public)")
        RuntimeDiagnostics.shared.record(message, category: category)
        if mirrorsToTestConsole { print(message) }
        lock.lock()
        entries.append(Entry(date: Date(), message: message))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        lock.unlock()
    }

    public func recentMessages(limit: Int) -> [String] {
        lock.lock()
        let snapshot = Array(entries.suffix(max(0, limit)))
        lock.unlock()
        return snapshot.map(\.message)
    }

    public func recentSummary(limit: Int = 20) -> String {
        lock.lock()
        let snapshot = Array(entries.suffix(max(0, limit)))
        lock.unlock()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return snapshot
            .map { "\(formatter.string(from: $0.date))  \($0.message)" }
            .joined(separator: "\n")
    }
}
