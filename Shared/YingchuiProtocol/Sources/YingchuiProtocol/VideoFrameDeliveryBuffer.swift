import Foundation

public struct VideoDeliveryGap: Sendable {
    public let frameID: UInt32
    public let missingFragments: [UInt16]?
    public let declaredAt: UInt64
}

/// 连续帧立即交付；仅缺口阻塞时有限等待，补发策略可提前发现后续帧分片。
public struct VideoFrameDeliveryBuffer: Sendable {
    private struct Pending: Sendable {
        let frame: CompletedVideoFrame
        let arrival: UInt64
    }
    private var reassembler: VideoFrameReassembler
    private var pending: [UInt32: Pending] = [:]
    private var lastDelivered: UInt32?
    private var awaitingKeyFrame = false
    public private(set) var lastGap: VideoDeliveryGap?
    private let maximumPendingFrames: Int
    private var reorderWaitNanoseconds: UInt64
    private let earlyRepairEnabled: Bool
    public private(set) var lastAssembledFrameID: UInt32?

    public init(maximumPendingFrames: Int = 6, repairEnabled: Bool = false, earlyRepairEnabled: Bool = false) {
        reorderWaitNanoseconds = repairEnabled ? 90_000_000 : 30_000_000
        self.earlyRepairEnabled = repairEnabled && earlyRepairEnabled
        self.maximumPendingFrames = max(1, maximumPendingFrames)
        reassembler = VideoFrameReassembler(maximumPendingFrames: maximumPendingFrames, defersDelivery: true)
    }

    /// 只在后续完整帧证明存在缺口后补发，不给正常连续帧增加等待。
    public var pendingRepairRequest: VideoRepairRequest? {
        repairRequest(now: DispatchTime.now().uptimeNanoseconds)
    }

    public func repairRequest(now: UInt64) -> VideoRepairRequest? {
        guard !awaitingKeyFrame, let lastDelivered,
              pending[lastDelivered &+ 1] == nil,
              !pending.values.contains(where: { $0.frame.isKeyFrame }) else { return nil }
        let hasLaterCompleteFrame = !pending.isEmpty
        let earlyDeadline = nextEarlyRepairDeadline
        guard hasLaterCompleteFrame || earlyDeadline.map({ now >= $0 }) == true else { return nil }
        let request = VideoRepairRequest(frameID: lastDelivered &+ 1,
            fragmentIndices: reassembler.missingFragments(for: lastDelivered &+ 1))
        return request.isValid ? request : nil
    }

    /// 后续帧已有分片但尚未完整时，保留四毫秒乱序宽限，避免立即制造重复流量。
    public var nextEarlyRepairDeadline: UInt64? {
        guard earlyRepairEnabled, !awaitingKeyFrame, let lastDelivered, pending.isEmpty,
              let first = reassembler.firstFragmentOfFrameNewer(than: lastDelivered &+ 1) else { return nil }
        return first + 4_000_000
    }

    /// 已开始的缺口期限不随新的校时样本移动。
    @discardableResult
    public mutating func updateRepairWaitNanoseconds(_ value: UInt64) -> Bool {
        guard pending.isEmpty else { return false }
        reorderWaitNanoseconds = min(90_000_000, max(40_000_000, value))
        return true
    }

    public var nextDeadline: UInt64? {
        guard !awaitingKeyFrame else { return nil }
        return pending.values.map(\.arrival).min().map { $0 + reorderWaitNanoseconds }
    }

    public mutating func append(_ fragment: VideoFragment,
        now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> [CompletedVideoFrame] {
        lastAssembledFrameID = nil
        guard !awaitingKeyFrame || fragment.isKeyFrame else { return drain(now: now) }
        if let frame = reassembler.append(fragment, receivedAtUptimeNanoseconds: now),
           pending[frame.frameID] == nil {
            pending[frame.frameID] = Pending(frame: frame, arrival: now)
            lastAssembledFrameID = frame.frameID
        }
        return drain(now: now)
    }

    public mutating func drain(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> [CompletedVideoFrame] {
        var result: [CompletedVideoFrame] = []
        while !pending.isEmpty {
            let candidate: Pending?
            if awaitingKeyFrame {
                candidate = pending.values.filter { $0.frame.isKeyFrame }.min {
                    Int32(bitPattern: $0.frame.frameID &- $1.frame.frameID) < 0
                }
            } else if let last = lastDelivered {
                let ordered = pending.values.sorted { ($0.frame.frameID &- last) < ($1.frame.frameID &- last) }
                if let next = pending[last &+ 1] {
                    candidate = next
                } else if let key = ordered.first(where: { $0.frame.isKeyFrame }) {
                    candidate = key
                } else if pending.count >= maximumPendingFrames || now >= (nextDeadline ?? UInt64.max) {
                    candidate = ordered.first
                } else {
                    break
                }
            } else {
                candidate = pending.values.min { $0.arrival < $1.arrival }
            }
            guard let candidate else { break }
            let id = candidate.frame.frameID
            if candidate.frame.isKeyFrame {
                awaitingKeyFrame = false
            } else if let last = lastDelivered, id &- last > 1 {
                lastGap = VideoDeliveryGap(frameID: last &+ 1,
                    missingFragments: reassembler.missingFragments(for: last &+ 1), declaredAt: now)
                // 缺口确认后仅交付一帧作为丢帧信号。后续普通帧不能推进水位，
                // 否则更晚收齐的恢复关键帧仍可能被当成过期帧。
                awaitingKeyFrame = true
            }
            result.append(candidate.frame)
            lastDelivered = id
            reassembler.discardThrough(frameID: id)
            pending = pending.filter { Int32(bitPattern: $0.key &- id) > 0 }
        }
        return result
    }

    public mutating func reset() {
        reassembler.reset()
        pending.removeAll(keepingCapacity: true)
        lastDelivered = nil
        awaitingKeyFrame = false
        lastGap = nil
        lastAssembledFrameID = nil
    }

    @discardableResult
    public mutating func discardIncompleteFrames(olderThanUptimeNanoseconds cutoff: UInt64) -> Int {
        reassembler.discardIncompleteFrames(olderThanUptimeNanoseconds: cutoff)
    }
}
