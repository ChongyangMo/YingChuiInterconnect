import UIKit
import YingchuiProtocol

final class PadDiagnosticsDelegate: NSObject, UIApplicationDelegate {
    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        RuntimeDiagnostics.shared.phase("收到系统内存警告")
    }

    func applicationWillTerminate(_ application: UIApplication) {
        RuntimeDiagnostics.shared.phase("收到系统退出通知", endingNormally: true)
    }
}
