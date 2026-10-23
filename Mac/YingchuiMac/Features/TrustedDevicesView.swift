import SwiftUI

struct TrustedDevicesView: View {
    @ObservedObject var host: MacHostModel
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDevice: TrustedDeviceSummary?

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("可信设备").font(.headline)
                Spacer()
                Button("完成") { dismiss() }
            }
            List(host.trustedDevices) { device in
                HStack {
                    Label(device.name, systemImage: "ipad")
                    Spacer()
                    Text(device.controlling ? "正在控制" : (device.connected ? "已连接" : "离线"))
                        .foregroundStyle(.secondary)
                    Button("撤销", role: .destructive) { pendingDevice = device }
                }.padding(.vertical, 4)
            }
            if host.trustedDevices.isEmpty { Text("暂无可信设备").foregroundStyle(.secondary) }
        }
        .padding(20).frame(width: 480, height: 320)
        .buttonStyle(.yingchuiSecondary)
        .confirmationDialog("撤销此设备的授权？", isPresented: Binding(
            get: { pendingDevice != nil }, set: { if !$0 { pendingDevice = nil } }
        ), titleVisibility: .visible) {
            Button("撤销并断开", role: .destructive) {
                if let device = pendingDevice { host.revokeDevice(device.id) }
                pendingDevice = nil
            }
            Button("取消", role: .cancel) { pendingDevice = nil }
        }
    }
}
