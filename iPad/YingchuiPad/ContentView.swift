import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = PadConnectionModel()
    @StateObject private var account = AccountModel()
    @State private var showAccount = false
    @State private var showKeyboard = false
    @State private var pairingCode = ""
    @State private var isVideoFullScreen = false
    @State private var isForgetConfirmationPresented = false
    @State private var showSettings = false
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            PadHostSidebar(
                hosts: model.discoveredHosts,
                discoveryStatus: model.discoveryStatus,
                onConnect: { host in
                    showSettings = false
                    preferredCompactColumn = .detail
                    if !model.isConnected || model.connectedHostKey != host.hostID {
                        model.connect(to: host)
                    }
                },
                onRefresh: model.restartBrowsing,
                isSettingsSelected: showSettings,
                onSettings: {
                    showSettings = true
                    preferredCompactColumn = .detail
                },
                selectedHostID: model.connectedHostKey,
                accountName: account.user?.displayName,
                isVIP: account.user?.vip == true,
                isAccountPresented: showAccount,
                onAccount: { showAccount = true }
            )
        } detail: {
            Group {
                if showSettings {
                    PadSettingsView(model: model) { isForgetConfirmationPresented = true }
                        .transition(.opacity.combined(with: .offset(y: 8)))
                } else if model.connectedHostName == nil && !model.requiresAllTrustReset {
                    ContentUnavailableView(
                        model.discoveredHosts.isEmpty ? model.discoveryStatus : "选择 Mac",
                        systemImage: model.discoveredHosts.isEmpty ? "network" : "macmini"
                    )
                } else {
                    ViewThatFits(in: .vertical) {
                        detailContent

                        scrollableDetail
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .yingchuiStatusMotion(showSettings)
            .navigationTitle(showSettings ? "设置" : "鹰锤互联")
            .navigationBarTitleDisplayMode(.inline)
        }
        .fullScreenCover(isPresented: $isVideoFullScreen) {
            FullScreenVideoView(model: model, isPresented: $isVideoFullScreen)
        }
        .sheet(isPresented: $showAccount) {
            PadAccountSheet(account: account)
        }
        .task {
            if NSClassFromString("XCTestCase") == nil { model.bindAccount(account); account.restoreOnce() }
        }
        .overlay(alignment: .bottom) { TransferStatusView(model: model) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !showSettings {
                    PadMoreMenu(model: model) { showKeyboard = true }
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                if !showSettings, model.lastHostID != nil {
                    Button("连接上次 Mac", systemImage: "bolt") {
                        showSettings = false
                        preferredCompactColumn = .detail
                        model.quickConnect()
                    }
                        .buttonStyle(.yingchuiPlain)
                }
            }
        }
        .modifier(RemoteKeyboardPresentation(model: model, isPresented: $showKeyboard, isActive: !isVideoFullScreen && !showSettings))
        .onChange(of: isVideoFullScreen) { _, isFullScreen in
            if isFullScreen { showKeyboard = false }
        }
        .onChange(of: showSettings) { _, isSettings in
            if isSettings { showKeyboard = false }
        }
        .onChange(of: model.shouldPresentFullScreen) { _, requested in
            if requested { isVideoFullScreen = true; model.shouldPresentFullScreen = false }
        }
        .physicalSmokeTest(model: model, isVideoFullScreen: $isVideoFullScreen)
        .confirmationDialog(
            model.requiresAllTrustReset ? "重置全部信任？" : "忘记此 Mac？",
            isPresented: $isForgetConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(model.requiresAllTrustReset ? "清除全部配对信息" : "忘记并断开", role: .destructive) {
                if model.requiresAllTrustReset {
                    model.forgetAllHostTrust()
                } else {
                    model.forgetCurrentHostTrust()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(model.requiresAllTrustReset
                ? "将清除此 iPad 保存的所有 Mac 配对信息，之后需要重新输入配对码。"
                : "下次连接需要重新输入配对码。")
        }
        .onAppear {
            model.refreshStreamingViewport()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.resumeAfterForeground()
                model.refreshStreamingViewport()
            } else if phase == .background {
                model.prepareForBackground()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            model.refreshStreamingViewport()
        }
        .onChange(of: model.connectedHostName) { _, _ in
            model.refreshStreamingViewport()
        }

    }

    private var scrollableDetail: some View {
        ScrollView(.vertical) {
            detailContent
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentMargins(.trailing, 0, for: .scrollIndicators)
        .scrollIndicators(.visible)
        .scrollDismissesKeyboard(.interactively)
    }

    private var detailContent: some View {
        VStack(spacing: 12) {
            if model.connectedHostName != nil || model.requiresAllTrustReset {
                connectionHeader
            }

            if model.isConnected && !model.isPaired {
                pairingCard
            }

            if model.isPaired {
                videoPanel
            }
        }
        .frame(maxWidth: 820)
        .padding(16)
    }

    private var connectionHeader: some View {
        PadConnectionHeader(model: model) {
            isForgetConfirmationPresented = true
        }
    }

    private var pairingCard: some View {
        PadPairingCard(model: model, pairingCode: $pairingCode)
    }

    private var videoPanel: some View {
        PadVideoPanel(model: model, isFullScreen: $isVideoFullScreen)
    }

}

#Preview {
    ContentView()
}
