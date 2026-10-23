import Foundation

struct PadPlaybackSnapshot: Sendable {
    let decodedFrames: UInt64
    let droppedFrames: UInt64
}

final class PadPlaybackStatistics: @unchecked Sendable {
    private let lock = NSLock()
    private var decodedFrames: UInt64 = 0
    private var droppedFrames: UInt64 = 0

    func recordDecodedFrame() {
        lock.lock()
        decodedFrames &+= 1
        lock.unlock()
    }

    func recordDroppedFrame() {
        lock.lock()
        droppedFrames &+= 1
        lock.unlock()
    }

    func snapshot() -> PadPlaybackSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return PadPlaybackSnapshot(
            decodedFrames: decodedFrames,
            droppedFrames: droppedFrames
        )
    }

    func reset() {
        lock.lock()
        decodedFrames = 0
        droppedFrames = 0
        lock.unlock()
    }
}
