import Foundation

enum PadPresentationAgePolicy {
    /// 两次刷新加两毫秒宽限；只在还有更新画面时追赶，保留细小抖动缓冲。
    static func discardCount(enqueuedAt: [UInt64], now: UInt64, refreshInterval: UInt64) -> Int {
        let budget = refreshInterval * 2 + 2_000_000
        var count = 0
        while count + 1 < enqueuedAt.count {
            let queued = enqueuedAt[count]
            guard now >= queued, now - queued > budget else { break }
            count += 1
        }
        return count
    }
}

enum PadVideoPresentationConfiguration {
    static let immediateInteraction: Bool = {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--legacy-interaction-presentation") { return false }
#endif
        return true
    }()

    static let ageLimited: Bool = {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--legacy-presentation-queue") { return false }
        if arguments.contains("--bounded-presentation-age") { return true }
#endif
        return true
    }()
}
