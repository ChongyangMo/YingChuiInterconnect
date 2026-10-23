import AppKit
import SwiftUI

struct MacMenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var host: MacHostModel

    var body: some View {
        Text(host.statusText)

        if host.isStreaming {
            Text("正在回传屏幕")
        }

        Divider()

        Button("打开主窗口") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }

        Button(host.isRunning ? "停止服务" : "启动服务") {
            host.isRunning ? host.stop() : host.restart()
        }

        Toggle(
            "开机时启动",
            isOn: Binding(
                get: { host.isLaunchAtLoginEnabled },
                set: { host.setLaunchAtLoginEnabled($0) }
            )
        )

        Divider()

        Button("恢复显示器") { host.restoreDisplayConfiguration() }
            .disabled(!host.isStreaming && !host.hasPendingDisplayRecovery)

        Button("退出") {
            NSApp.terminate(nil)
        }
    }
}
