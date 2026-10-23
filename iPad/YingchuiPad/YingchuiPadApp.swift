import SwiftUI
import YingchuiProtocol

@main
struct YingchuiPadApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(PadDiagnosticsDelegate.self) private var diagnostics

    init() {
        if NSClassFromString("XCTestCase") == nil { RuntimeDiagnostics.shared.start() }
    }

    var body: some Scene {
        WindowGroup {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--layout-smoke-test") {
                FullScreenLayoutSmokeTestView()
            } else {
                ContentView()
            }
#else
            ContentView()
#endif
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: RuntimeDiagnostics.shared.phase("前台活动")
            case .inactive: RuntimeDiagnostics.shared.phase("离开活动状态")
            case .background: RuntimeDiagnostics.shared.phase("进入后台，系统可能挂起或回收进程")
            @unknown default: RuntimeDiagnostics.shared.phase("未知应用状态")
            }
        }
    }
}
