import Foundation

struct MacIdleFramePolicy {
    private var lastEncoded: UInt64?
    private var lastChanged: UInt64?

    mutating func shouldEncode(isIdle: Bool, hasImage: Bool, forceKeyFrame: Bool,
                               now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
        guard hasImage else { return false }
        if !isIdle { lastChanged = now }
        // 动画刚结束时保留短暂细节收敛期，避免低码率的最后一帧停留整整一秒。
        // 仅响应真实 idle 回调，不在采集中断时伪造画面。
        let isSettling = lastChanged.map { now >= $0 && now - $0 <= 350_000_000 } ?? false
        let interval: UInt64 = isSettling ? 33_333_333 : 1_000_000_000
        if isIdle, !forceKeyFrame, let lastEncoded, now >= lastEncoded,
           now - lastEncoded < interval { return false }
        lastEncoded = now
        return true
    }
}
