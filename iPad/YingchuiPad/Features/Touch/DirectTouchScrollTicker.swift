import UIKit

@MainActor
final class DirectTouchScrollTicker {
    private let session: DirectTouchScrollSession
    private var displayLink: CADisplayLink?
    private let target = ScrollFrameTarget()

    init(session: DirectTouchScrollSession) {
        self.session = session
        target.onFrame = { [weak session] in
            session?.tick(now: ProcessInfo.processInfo.systemUptime)
        }
        session.onNeedsFrames = { [weak self] needed in self?.setActive(needed) }
    }

    isolated deinit { displayLink?.invalidate() }

    private func setActive(_ active: Bool) {
        if !active {
            displayLink?.invalidate()
            displayLink = nil
        } else if displayLink == nil {
            let link = CADisplayLink(target: target, selector: #selector(ScrollFrameTarget.frame))
            link.preferredFramesPerSecond = 60
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }
}

@MainActor
private final class ScrollFrameTarget: NSObject {
    var onFrame: (() -> Void)?
    @objc func frame() { onFrame?() }
}
