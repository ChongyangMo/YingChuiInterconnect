import Foundation

/// 所有状态只在采集队列访问；总待发包数由发送端的预约额度限制。
final class MacVideoDatagramPacer: @unchecked Sendable {
    private struct Pending {
        let packets: [Data]
        let copies: Int
        let send: ([Data]) -> Void
        let onTiming: ((UInt64, UInt64) -> Void)?
        let enqueuedAt: UInt64
        var startedAt: UInt64?
        var offset = 0
        let intervalMicroseconds: Int
        var isReplica: Bool { offset >= packets.count }
    }

    private let queue: DispatchQueue
    private var pending: [Pending] = []
    private var wakeup: DispatchWorkItem?
    private var generation = UUID()
    var acceleratesLargeFrames = true

    var oldestQueuedAgeNanoseconds: UInt64 {
        guard let oldest = pending.map(\.enqueuedAt).min() else { return 0 }
        let now = DispatchTime.now().uptimeNanoseconds
        return now >= oldest ? now - oldest : 0
    }

    init(queue: DispatchQueue) { self.queue = queue }

    func enqueue(_ packets: [Data], copies: Int, priority: Bool = false, onTiming: ((UInt64, UInt64) -> Void)? = nil,
                 send: @escaping ([Data]) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        precondition(!packets.isEmpty && copies > 0)
        let frame = Pending(packets: packets, copies: copies, send: send,
            onTiming: onTiming, enqueuedAt: DispatchTime.now().uptimeNanoseconds,
            intervalMicroseconds: acceleratesLargeFrames && packets.count >= 64 && !priority ? 500 : 1_000)
        if priority {
            pending.insert(frame, at: 0)
        } else {
            // 新画面的首份数据先于旧关键帧副本；副本仍按原包数发送。
            pending.insert(frame, at: pending.firstIndex(where: \.isReplica) ?? pending.endIndex)
        }
        if wakeup == nil { drain() }
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(queue))
        generation = UUID()
        wakeup?.cancel()
        wakeup = nil
        pending.removeAll(keepingCapacity: true)
    }

    private func drain() {
        guard !pending.isEmpty else { wakeup = nil; return }
        var frame = pending.removeFirst()
        if frame.startedAt == nil { frame.startedAt = DispatchTime.now().uptimeNanoseconds }
        // 一批不跨副本边界，首份完整后允许下一帧先走。
        let copyEnd = (frame.offset / frame.packets.count + 1) * frame.packets.count
        let end = min(frame.offset + 8, copyEnd)
        let batch = (frame.offset..<end).map { frame.packets[$0 % frame.packets.count] }
        frame.offset = end
        if end < frame.packets.count * frame.copies {
            if frame.isReplica { pending.append(frame) } else { pending.insert(frame, at: 0) }
        }
        frame.send(batch)
        if end == frame.packets.count * frame.copies, let started = frame.startedAt {
            frame.onTiming?(started - frame.enqueuedAt, DispatchTime.now().uptimeNanoseconds - started)
        }

        // 大帧首份缩短批次等待，但不扩大单批突发。副本沿用原有节奏，调度延迟后不追赶。
        let interval = frame.isReplica ? 1_000 : frame.intervalMicroseconds
        let currentGeneration = generation
        let next = DispatchWorkItem { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.drain()
        }
        wakeup = next
        queue.asyncAfter(deadline: .now() + .microseconds(interval), execute: next)
    }
}
