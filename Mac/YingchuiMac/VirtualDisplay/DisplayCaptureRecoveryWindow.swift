import Foundation

struct DisplayCaptureRecoveryWindow {
    private var deadline: TimeInterval?

    mutating func displayChanged(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        deadline = now + 8
    }

    mutating func consume(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        defer { deadline = nil }
        guard let deadline else { return false }
        return now <= deadline
    }

    mutating func reset() { deadline = nil }
}
