import AVFoundation
import UIKit
import YingchuiProtocol

/// 压缩帧全部保留解码；已解码图像限制容量，并可按停留时间淘汰过期画面。
@MainActor
final class PadVideoPresentationQueue {
    var onDisplay: ((CVPixelBuffer, CompletedVideoFrame) -> Bool)?
    var onCoalesced: ((CompletedVideoFrame) -> Void)?
    var onClockGap: ((UInt64) -> Void)?
    var onQueueTiming: ((CompletedVideoFrame, UInt64, UInt64, Int, Bool) -> Void)?
    private var interactionPolicy = PadInteractionPresentationPolicy()
    private struct Pending {
        let image: CVPixelBuffer
        let frame: CompletedVideoFrame
        let enqueuedAt: UInt64
    }
    private var pending: [Pending] = []
    private var displayLink: CADisplayLink?
    private lazy var clock = PadVideoPresentationClock(owner: self)
    private var hasPresented = false
    private var lastActivityUptime: UInt64 = 0
    private var lastTickUptime: UInt64?
    private var refreshInterval: UInt64 = 16_666_667

    func prepareForInteraction() {
        lastActivityUptime = DispatchTime.now().uptimeNanoseconds
        interactionPolicy.prepare(now: lastActivityUptime)
        resumeClock()
    }

    @discardableResult
    func submit(_ image: CVPixelBuffer, frame: CompletedVideoFrame) -> Bool {
        lastActivityUptime = DispatchTime.now().uptimeNanoseconds
        let immediateInteraction = interactionPolicy.consumeFrame(now: lastActivityUptime, hasPendingPictures: !pending.isEmpty)
            && PadVideoPresentationConfiguration.immediateInteraction
        if !hasPresented || immediateInteraction {
            hasPresented = true
            onQueueTiming?(frame, lastActivityUptime, lastActivityUptime, 0, immediateInteraction)
            return onDisplay?(image, frame) ?? false
        }
        if pending.count == 3 { onCoalesced?(pending.removeFirst().frame) }
        pending.append(Pending(image: image, frame: frame, enqueuedAt: lastActivityUptime))
        resumeClock()
        return true
    }

    private func resumeClock() {
        if displayLink == nil {
            let link = CADisplayLink(target: clock, selector: #selector(PadVideoPresentationClock.tick))
            let screen = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first(where: { $0.activationState == .foregroundActive })?.screen ?? UIScreen.main
            let maximum = Float(screen.maximumFramesPerSecond)
            refreshInterval = UInt64(ceil(1_000_000_000 / Double(maximum)))
            // 活动画面按屏幕原生节奏交付，不能在动画中自行退到半刷新率。
            link.preferredFrameRateRange = CAFrameRateRange(minimum: maximum, maximum: maximum, preferred: maximum)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        if displayLink?.isPaused == true { lastTickUptime = nil }
        displayLink?.isPaused = false
    }

    fileprivate func flush() {
        let now = DispatchTime.now().uptimeNanoseconds
        if let lastTickUptime, now >= lastTickUptime { onClockGap?(now - lastTickUptime) }
        lastTickUptime = now
        guard !pending.isEmpty else {
            // 包到达与屏幕刷新不同相；队列暂空时保持时钟，避免逐帧停启漏掉下一拍。
            if now >= lastActivityUptime, now - lastActivityUptime >= 500_000_000 {
                displayLink?.isPaused = true
                lastTickUptime = nil
            }
            return
        }
        let depth = pending.count
        if PadVideoPresentationConfiguration.ageLimited {
            let discard = PadPresentationAgePolicy.discardCount(enqueuedAt: pending.map(\.enqueuedAt),
                now: now, refreshInterval: refreshInterval)
            for _ in 0..<discard { onCoalesced?(pending.removeFirst().frame) }
        }
        let sample = pending.removeFirst()
        onQueueTiming?(sample.frame, sample.enqueuedAt, now, depth, false)
        _ = onDisplay?(sample.image, sample.frame)
    }

    func reset() {
        displayLink?.invalidate()
        displayLink = nil
        pending.removeAll()
        hasPresented = false
        lastActivityUptime = 0
        lastTickUptime = nil
        interactionPolicy = PadInteractionPresentationPolicy()
    }

    isolated deinit { displayLink?.invalidate() }
}

@MainActor
private final class PadVideoPresentationClock: NSObject {
    weak var owner: PadVideoPresentationQueue?
    init(owner: PadVideoPresentationQueue) { self.owner = owner }
    @objc func tick() { owner?.flush() }
}
