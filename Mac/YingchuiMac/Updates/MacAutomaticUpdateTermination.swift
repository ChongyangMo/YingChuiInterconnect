import AppKit
import Sparkle
import YingchuiProtocol

@MainActor
enum MacAutomaticUpdateTermination {
    static weak var controller: MacUpdateController?

    static func shouldTerminate(_ application: NSApplication) -> NSApplication.TerminateReply {
        guard let updates = controller else { return .terminateNow }
        if updates.installationCommitted {
            guard updates.isIdle() else {
                updates.state = .deferred
                // 退出被新任务阻止时，重试仍须重新核验固定版本。
                Task { @MainActor in updates.userDriver?.retryTerminationWhenIdle() }
                return .terminateCancel
            }
            return .terminateNow
        }
        guard updates.sparkle?.sessionInProgress == true else { return .terminateNow }
        updates.isTerminating = true
        // 用户主动退出时先确认下载/待安装会话已取消，避免组件在退出时安装未经最终核验的包。
        updates.sessionID = nil
        updates.installation.cancel()
        updates.userDriver?.cancelCurrentInteraction()
        Task { @MainActor in
            for _ in 0..<150 {
                if updates.sparkle?.sessionInProgress != true {
                    application.reply(toApplicationShouldTerminate: true)
                    return
                }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
            }
            updates.message = "更新尚未安全停止，请稍后再退出。"
            updates.isTerminating = false
            updates.log.record("退出已延期：更新会话尚未安全停止")
            application.reply(toApplicationShouldTerminate: false)
        }
        return .terminateLater
    }
}
