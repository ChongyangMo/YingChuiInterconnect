import AppKit
import YingchuiProtocol

final class MacDiagnosticsDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard NSClassFromString("XCTestCase") == nil else { return .terminateNow }
        let source = sender.currentEvent?.type == .keyDown ? "键盘快捷键" : "菜单或系统退出请求"
        RuntimeDiagnostics.shared.phase("收到退出请求：\(source)")
        return MacAutomaticUpdateTermination.shouldTerminate(sender)
    }

    func applicationWillTerminate(_ notification: Notification) {
        RuntimeDiagnostics.shared.phase("正常退出", endingNormally: true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        RuntimeDiagnostics.shared.phase("前台活动")
    }

    func applicationDidResignActive(_ notification: Notification) {
        RuntimeDiagnostics.shared.phase("后台运行")
    }
}
