import SwiftUI

struct MacSettingsView: View {
    @ObservedObject var host: MacHostModel
    @ObservedObject var updates: MacUpdateController
    @State private var showTrustedDevices = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                YingchuiPanelIcon(systemName: "slider.horizontal.3", size: 44)
                Text("设置").font(.title2.weight(.semibold))
                Spacer()
            }
            YingchuiPanel {
                Button { host.restart() } label: {
                    YingchuiPanelRowLabel(title: host.isRunning ? "重启服务" : "启动服务", systemName: "arrow.clockwise")
                }
                .accessibilityLabel(host.isRunning ? "重启服务" : "启动服务")
                YingchuiPanelDivider()
                Button(role: .destructive) { host.stop() } label: {
                    YingchuiPanelRowLabel(title: "停止", systemName: "stop.circle", tint: .red)
                }
                .disabled(!host.isRunning)
                .accessibilityLabel("停止")
            }
            YingchuiPanel {
                Button { host.restoreDisplayConfiguration() } label: {
                    YingchuiPanelRowLabel(title: "恢复显示器", systemName: "display")
                }
                .disabled(!host.hasPendingDisplayRecovery && !host.isStreaming)
                .accessibilityLabel("恢复显示器")
                YingchuiPanelDivider()
                Button { showTrustedDevices = true } label: {
                    YingchuiPanelRowLabel(title: "可信设备", systemName: "checkmark.shield", showsChevron: true)
                }
                .disabled(host.pairedDeviceCount == 0)
                .accessibilityLabel("可信设备")
            }
            YingchuiPanel {
                Button { updates.checkForUpdates() } label: {
                    YingchuiPanelRowLabel(title: updates.buttonTitle, systemName: "arrow.down.circle")
                }
                .disabled(!updates.canCheck || updates.hasDeferredInstallation)
                .accessibilityLabel(updates.buttonTitle)
            }
        }
        .buttonStyle(.yingchuiRow)
        .padding(24)
        .frame(width: 420)
        .background { YingchuiPanelBackground() }
        .navigationTitle("设置")
        .fixedSize(horizontal: false, vertical: true)
        .alert("应用更新", isPresented: Binding(get: { updates.message != nil }, set: { if !$0 { updates.message = nil } })) {
            Button("好", role: .cancel) { updates.message = nil }
        } message: { Text(updates.message ?? "") }
        .sheet(isPresented: $showTrustedDevices) { TrustedDevicesView(host: host) }
    }
}
