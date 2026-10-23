import Foundation

struct PadVideoReceiveSnapshot: Sendable {
    let generation: UUID
    let streamID: UUID
    let uptimeNanoseconds: UInt64
    let packets: UInt64
    let assembled: UInt64
    let dropped: UInt64
    let networkMissing: UInt64?

    init(generation: UUID, streamID: UUID, uptimeNanoseconds: UInt64, packets: UInt64,
         assembled: UInt64, dropped: UInt64, networkMissing: UInt64? = nil) {
        self.generation = generation; self.streamID = streamID; self.uptimeNanoseconds = uptimeNanoseconds
        self.packets = packets; self.assembled = assembled; self.dropped = dropped; self.networkMissing = networkMissing
    }
}

/// 使用单调时间判断停滞，不把主线程积压后连续执行的统计回调当成多秒无帧。
struct PadVideoStallPolicy {
    enum Action: Equatable, Sendable { case none, requestKeyFrame, recover }
    private var lastProgress: UInt64?
    private var lastProbe: UInt64?

    mutating func recordProgress(now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lastProgress = now
        lastProbe = nil
    }

    mutating func evaluate(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Action {
        guard let lastProgress, now >= lastProgress else { return .none }
        let elapsed = now - lastProgress
        if elapsed >= 4_000_000_000 { return .recover }
        guard elapsed >= 2_000_000_000 else { return .none }
        if let lastProbe, now < lastProbe || now - lastProbe < 1_000_000_000 { return .none }
        lastProbe = now
        return .requestKeyFrame
    }
}
