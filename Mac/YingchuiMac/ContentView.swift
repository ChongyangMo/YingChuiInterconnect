import YingchuiProtocol
import SwiftUI

struct ContentView: View {
    @ObservedObject var host: MacHostModel
    @ObservedObject var account: AccountModel
    @State private var showAccount = false
    @State private var isRuntimeDetailsExpanded = false
    @ScaledMetric(relativeTo: .title) private var pairingCodeSize = 28

    var body: some View {
        dashboard
        .fixedSize(horizontal: false, vertical: true)
        .frame(minWidth: 500, alignment: .top)
        .buttonStyle(.yingchuiSecondary)
        .sheet(isPresented: $showAccount) { AccountView(account: account) }
    }

    private var dashboard: some View {
        VStack(spacing: 12) {
            header
            metrics
            pairingCode
            tlsRecoveryNotice
            permissions
            if let name = host.activeControllerName { Text("\(name) 正在控制").font(.caption).foregroundStyle(.secondary) }
            streamPanel
            runtimeDetails
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: host.isRunning ? "network.badge.shield.half.filled" : "network.slash")
                .font(.system(size: 30))
                .foregroundStyle(host.isRunning ? .green : .secondary)
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("鹰锤互联")
                    .font(.title2.bold())
                Text(host.statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button { showAccount = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: account.user == nil ? "person.crop.circle" : "person.crop.circle.fill")
                        .font(.title2)
                    if account.user?.vip == true { AccountVIPBadge() }
                }
            }
            .buttonStyle(.yingchuiPlain)
            .accessibilityLabel(account.user == nil ? "登录账号" : "管理账号")
            .accessibilityValue(account.user?.vip == true ? "VIP" : "")
            .help(account.user?.displayName ?? "登录")

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.title2)
            }
            .buttonStyle(.yingchuiPlain)
            .accessibilityLabel("设置")
            .help("设置")

            MacInfoButton(title: "连接服务", information: { MacDashboardTopic.service.information(for: host) }) {
                Text(host.isRunning ? "服务在线" : "服务停止")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(host.isRunning ? .green : .secondary)
            }
        }
    }

    private var metrics: some View {
        HStack(spacing: 8) {
            metric(title: "端口", value: host.portText, topic: .port)
            metric(title: "连接", value: "\(host.connectedClientCount)", topic: .connections)
            metric(title: "可信", value: "\(host.pairedDeviceCount)", topic: .trusted)
        }
    }

    private var pairingCode: some View {
        MacInfoButton(title: "首次配对", information: { MacDashboardTopic.pairing.information(for: host) }) {
            HStack(spacing: 12) {
                Label("iPad 首次配对", systemImage: "number.square")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(host.pairingCodeText)
                    .font(.system(size: pairingCodeSize, weight: .bold, design: .monospaced))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
        }
        .accessibilityValue(host.pairingCodeText)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var permissions: some View {
        VStack(spacing: 6) {
            permissionRow(
                title: "辅助功能", topic: .accessibility,
                granted: host.isAccessibilityGranted,
                grantedIcon: "checkmark.shield.fill",
                missingIcon: "exclamationmark.shield"
            ) {
                if host.isAccessibilityGranted {
                    host.refreshAccessibilityStatus()
                } else {
                    host.requestAccessibilityAccess()
                }
            }

            permissionRow(
                title: "屏幕录制", topic: .screenRecording,
                granted: host.isScreenCaptureGranted,
                grantedIcon: "rectangle.inset.filled.and.person.filled",
                missingIcon: "rectangle.dashed.badge.record"
            ) {
                if host.isScreenCaptureGranted {
                    host.refreshScreenCaptureStatus()
                } else {
                    host.requestScreenCaptureAccess()
                }
            }
        }
    }

    @ViewBuilder
    private var tlsRecoveryNotice: some View {
        if host.didRebuildTLSIdentity {
            MacInfoButton(title: "重新配对", information: { MacDashboardTopic.identity.information(for: host) }) {
                Label("请在 iPad 重置信任并重新配对", systemImage: "key.viewfinder")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var streamPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            MacInfoButton(title: "屏幕回传", information: { MacDashboardTopic.stream.information(for: host) }) {
                HStack {
                    Label(
                        host.activeDisplayState?.mode.title ?? (host.isStreaming ? "正在屏幕回传" : "屏幕回传待机"),
                        systemImage: host.isStreaming ? "dot.radiowaves.left.and.right" : "display"
                    )
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(host.isStreaming ? .green : .primary)
                    Spacer()
                    Text(host.streamStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if !host.availableDisplays.isEmpty {
                HStack(spacing: 8) {
                    Picker(
                        "回传显示器",
                        selection: host.displaySelectionBinding
                    ) {
                        if host.displaySelectionBinding.wrappedValue == nil {
                            Text("选择显示器").tag(nil as CGDirectDisplayID?)
                        }
                        ForEach(host.availableDisplays) { display in
                            Text("\(display.name) · \(display.resolution)").tag(Optional(display.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button("刷新", systemImage: "arrow.clockwise") {
                        host.refreshDisplays()
                    }
                }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var runtimeDetails: some View {
        DisclosureGroup(isExpanded: $isRuntimeDetailsExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text("编码是 Mac 输出的帧数，客户端解码是 iPad 已解码的帧数；丢弃是 Mac 端丢弃的帧数。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("编码 \(host.encodedFrameCount) · 丢弃 \(host.droppedFrameCount) · 客户端解码 \(host.clientDecodedFrameCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let lastClientName = host.lastClientName {
                    Label("最近设备：\(lastClientName)", systemImage: "ipad")
                        .font(.caption)
                }
                Toggle(
                    "开机时启动 · \(host.launchAtLoginStatusText)",
                    isOn: Binding(
                        get: { host.isLaunchAtLoginEnabled },
                        set: { host.setLaunchAtLoginEnabled($0) }
                    )
                )
                .toggleStyle(.switch)
            }
            .padding(.top, 8)
        } label: {
            Label("运行详情", systemImage: "gauge.with.dots.needle.50percent")
                .font(.subheadline.weight(.medium))
        }
        .disclosureGroupStyle(MacDisclosureGroupStyle())
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func permissionRow(
        title: String,
        topic: MacDashboardTopic,
        granted: Bool,
        grantedIcon: String,
        missingIcon: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            MacInfoButton(title: title, information: { topic.information(for: host) }) {
                Label(
                    granted ? "\(title)已授权" : "需要\(title)权限",
                    systemImage: granted ? grantedIcon : missingIcon
                )
                .font(.subheadline)
                .foregroundStyle(granted ? .green : .orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
            Button(granted ? "刷新" : "授权", action: action)
        }
        .frame(minHeight: 28)
    }

    private func metric(title: String, value: String, topic: MacDashboardTopic) -> some View {
        MacInfoButton(title: title, information: { topic.information(for: host) }) {
            VStack(spacing: 5) {
                Text(value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .accessibilityValue(value)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    ContentView(host: MacHostModel(), account: AccountModel())
}
