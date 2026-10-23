import Foundation

/// 仅为静止后的首次交互画面提供一次直接提交机会，后续仍由显示时钟调度。
struct PadInteractionPresentationPolicy {
    private var lastFrameAt: UInt64?
    private var preparedAt: UInt64?

    mutating func prepare(now: UInt64) {
        guard let lastFrameAt, now >= lastFrameAt, now - lastFrameAt >= 100_000_000 else { return }
        preparedAt = now
    }

    mutating func consumeFrame(now: UInt64, hasPendingPictures: Bool) -> Bool {
        defer { lastFrameAt = now; preparedAt = nil }
        guard !hasPendingPictures, let preparedAt, now >= preparedAt,
              now - preparedAt <= 250_000_000 else { return false }
        return true
    }
}
