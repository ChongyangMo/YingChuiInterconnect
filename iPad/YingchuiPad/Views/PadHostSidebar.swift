import SwiftUI

struct PadHostSidebar: View {
    let hosts: [DiscoveredHost]
    let discoveryStatus: String
    let onConnect: (DiscoveredHost) -> Void
    let onRefresh: () -> Void
    let isSettingsSelected: Bool
    let onSettings: () -> Void
    var selectedHostID: String? = nil
    var accountName: String? = nil
    var isVIP = false
    var isAccountPresented = false
    var onAccount: () -> Void = {}

    var body: some View {
        List {
            if hosts.isEmpty {
                ContentUnavailableView(discoveryStatus, systemImage: "network")
                    .listRowBackground(Color.clear)
            }
            ForEach(hosts) { host in
                hostRow(host)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 16) {
                PadSidebarIcon(title: "设置", symbol: "gearshape", selected: isSettingsSelected, action: onSettings)
                    .accessibilityIdentifier("settings-entry")
                Spacer(minLength: 8)
                PadSidebarIcon(title: "我的", symbol: "person.crop.circle", selected: isAccountPresented,
                               isVIP: isVIP, action: onAccount)
                    .accessibilityValue((accountName ?? "未登录") + (isVIP ? "，VIP" : ""))
                    .accessibilityIdentifier("account-entry")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .navigationTitle("鹰锤互联")
        .toolbar {
            ToolbarItem {
                Button("重新扫描", systemImage: "arrow.clockwise", action: onRefresh)
                    .buttonStyle(.yingchuiPlain)
            }
        }
    }

    private func hostRow(_ host: DiscoveredHost) -> some View {
        let selected = host.hostID == selectedHostID && !isSettingsSelected
        return Button { onConnect(host) } label: {
            HStack(spacing: 10) {
                Image(systemName: "macmini")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
                Text(host.name)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Image(systemName: selected ? "checkmark" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background {
                if selected { PadSidebarSelection() }
            }
        }
        .buttonStyle(.yingchuiRow)
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .yingchuiStatusMotion(selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PadSidebarIcon: View {
    let title: String
    let symbol: String
    let selected: Bool
    var isVIP = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                animatedIcon
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(selected ? Color.accentColor : .primary)
                if isVIP { AccountVIPBadge() }
            }
            .padding(.horizontal, isVIP ? 8 : 0)
            .frame(minWidth: 44, minHeight: 44)
            .background { if selected { PadSidebarSelection() } }
        }
        .buttonStyle(.yingchuiRow)
        .foregroundStyle(selected ? Color.accentColor : .primary)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(title)
        .yingchuiStatusMotion(selected)
    }

    @ViewBuilder private var animatedIcon: some View {
        if reduceMotion { Image(systemName: symbol) }
        else {
            Image(systemName: symbol)
                .symbolEffect(.bounce, options: .speed(1.5), value: selected)
        }
    }
}

private struct PadSidebarSelection: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.blue.opacity(scheme == .dark ? 0.24 : 0.12))
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.blue, lineWidth: 1)
                }
            }
    }
}
