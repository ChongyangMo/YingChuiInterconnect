import AppKit
import Foundation

final class MacSystemObserver {
    private var workspaceTokens: [NSObjectProtocol] = []
    private var applicationTokens: [NSObjectProtocol] = []

    init(
        onSleep: @escaping @Sendable () -> Void,
        onWake: @escaping @Sendable () -> Void,
        onDisplaysChanged: @escaping @Sendable () -> Void,
        onApplicationActive: @escaping @Sendable () -> Void
    ) {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { _ in onSleep() }
        )
        workspaceTokens.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { _ in onWake() }
        )

        let applicationCenter = NotificationCenter.default
        applicationTokens.append(
            applicationCenter.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { _ in onDisplaysChanged() }
        )
        applicationTokens.append(
            applicationCenter.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in onApplicationActive() }
        )
    }

    deinit {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceTokens.forEach(workspaceCenter.removeObserver)
        let applicationCenter = NotificationCenter.default
        applicationTokens.forEach(applicationCenter.removeObserver)
    }
}
