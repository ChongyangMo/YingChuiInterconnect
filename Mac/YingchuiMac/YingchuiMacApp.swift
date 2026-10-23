import Foundation
import SwiftUI
import YingchuiProtocol

@main
struct YingchuiMacApp: App {
    @NSApplicationDelegateAdaptor(MacDiagnosticsDelegate.self) private var diagnostics
    @StateObject private var host: MacHostModel
    @StateObject private var account = AccountModel()
    @StateObject private var updates = MacUpdateController()
    @StateObject private var management = MacManagementController()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let isRunningTests = NSClassFromString("XCTestCase") != nil
        if !isRunningTests { RuntimeDiagnostics.shared.start() }
        _host = StateObject(wrappedValue: MacHostModel(startServices: !isRunningTests))
    }

    var body: some Scene {
        WindowGroup("鹰锤互联", id: "main") {
            ContentView(host: host, account: account)
                .disabled(updates.installationCommitted)
                .task {
                    if NSClassFromString("XCTestCase") == nil {
                        host.bindAccount(account)
                        management.start(account: account, host: host, updates: updates)
                        account.restoreOnce()
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !updates.installationCommitted && NSClassFromString("XCTestCase") == nil && account.hasStoredSession {
                account.restore()
            }
        }
        .defaultSize(width: 540, height: 460)
        .windowResizability(.contentSize)

        Settings {
            MacSettingsView(host: host, updates: updates)
                .disabled(updates.installationCommitted)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MacMenuBarView(host: host)
                .disabled(updates.installationCommitted)
        } label: {
            Label(
                "鹰锤互联",
                systemImage: host.isRunning ? "network" : "network.slash"
            )
        }
    }
}
