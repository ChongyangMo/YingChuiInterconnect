import Combine
import AppKit
import CoreGraphics
import Foundation
import Network
import Security
import YingchuiProtocol

struct MacDisplayOption: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let resolution: String
}

final class MacHostModel: ObservableObject, @unchecked Sendable {
    @Published var hasPendingDisplayRecovery = false
    @Published var trustedDevices: [TrustedDeviceSummary] = []
    @Published var activeControllerName: String?
    var controlSessionID: UUID?
    var deviceNames: [String: String] = [:]
    var trustedDeviceWriter: (([String: String]) throws -> Void)?
    var persistsDeviceMetadata = false
    @Published var isRunning = false
    @Published var statusText = "正在启动局域网服务"
    @Published var connectedClientCount = 0
    @Published var portText = "—"
    @Published var lastClientName: String?
    @Published var pairingCodeText: String
    @Published var pairedDeviceCount: Int
    @Published var isAccessibilityGranted: Bool
    @Published var isScreenCaptureGranted: Bool
    @Published var isStreaming = false
    @Published var streamStatusText = "尚未开始屏幕回传"
    @Published var encodedFrameCount: UInt64 = 0
    @Published var droppedFrameCount: UInt64 = 0
    @Published var clientDecodedFrameCount: UInt64 = 0
    @Published var availableDisplays: [MacDisplayOption] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var isLaunchAtLoginEnabled: Bool
    @Published var launchAtLoginStatusText: String
    @Published var didRebuildTLSIdentity = false

    static let trustedDeviceTokensKey = "YingchuiTrustedDeviceTokens"
    static let secureStoreService = "com.yingchui.interconnect.mac"
    static let secureStoreAccount = "trusted-device-tokens-v1"
    static let selectedDisplayKey = "YingchuiSelectedDisplayID"
    static let hostIDKey = "YingchuiMacHostID"

    @MainActor weak var linkedAccount: AccountModel?
    let networkQueue = DispatchQueue(label: "com.yingchui.mac.host")
    lazy var usbHost = MacUSBHostManager(queue: networkQueue, log: eventLog)
    let eventLog = DiagnosticEventLog(
        subsystem: "com.yingchui.interconnect.mac",
        category: "主机"
    )
    let inputController = MacInputController()
    let screenStreamer = MacScreenStreamer()
    let streamPowerActivity = MacStreamPowerActivity()
    let virtualDisplayManager: MacVirtualDisplayManager
    let networkPathObserver = LocalNetworkPathObserver()
    let hostID: String
    var tlsIdentity: SecIdentity?
    var tlsIdentityErrorText: String?
    var listener: NWListener?
    var sessions: [UUID: HostPeerSession] = [:]
    var pairingCode: String
    var pairingPolicy = PairingAttemptPolicy(now: ProcessInfo.processInfo.systemUptime)
    var pairingTimer: DispatchSourceTimer?
    var trustedDeviceTokens: [String: String]
    var credentialStoreErrorText: String?
    var preferredDisplayID: CGDirectDisplayID?
    let selectedDisplayForStreaming = SynchronizedValue<CGDirectDisplayID?>(nil)
    var streamingSessionID: UUID?
    let cursorGeneration = SynchronizedValue(UUID())
    @MainActor var cursorMonitor: MacCursorMonitor?
    var streamDisplayPlacement: RemoteDisplayPlacement = .right
    @Published var activeDisplayState: RemoteDisplayState?
    var systemObserver: MacSystemObserver?
    var displayTopologyWorkItem: DispatchWorkItem?
    var listenerRetryWorkItem: DispatchWorkItem?
    var listenerRetryID: UUID?
    var listenerRetryAttempt = 0
    var lastNetworkState: LocalNetworkState?
    var wantsServiceRunning = true
    let automaticUpdateBarrier = SynchronizedValue(false)

    init(startServices: Bool = true) {
        // 测试主机不能恢复或清除真实用户的显示配置。
        let displayRecoveryStore = startServices ? DisplayRecoveryStore() : DisplayRecoveryStore(
            url: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                .appending(path: "display-recovery.json")
        )
        virtualDisplayManager = MacVirtualDisplayManager(recoveryStore: displayRecoveryStore)
        if let savedHostID = UserDefaults.standard.string(forKey: Self.hostIDKey),
           UUID(uuidString: savedHostID) != nil {
            hostID = savedHostID
        } else {
            let newHostID = UUID().uuidString
            UserDefaults.standard.set(newHostID, forKey: Self.hostIDKey)
            hostID = newHostID
        }
        if startServices {
            do {
                let result = try MacTLSIdentityStore.loadOrCreate()
                tlsIdentity = result.identity
                tlsIdentityErrorText = nil
                didRebuildTLSIdentity = result.didRebuildAfterAuthorizationFailure
            } catch {
                tlsIdentity = nil
                tlsIdentityErrorText = "TLS 本机身份初始化失败：\(error.localizedDescription)"
            }
        } else {
            tlsIdentity = nil
            tlsIdentityErrorText = nil
        }
        let savedTokens: [String: String]
        if startServices {
            do {
                savedTokens = try SecureDictionaryStore.load(
                    service: Self.secureStoreService,
                    account: Self.secureStoreAccount,
                    legacyDefaultsKey: Self.trustedDeviceTokensKey
                )
                credentialStoreErrorText = nil
            } catch {
                savedTokens = [:]
                credentialStoreErrorText = "可信设备读取失败：\(error.localizedDescription)"
            }
        } else {
            savedTokens = [:]
            credentialStoreErrorText = nil
        }
        let initialCode = Self.makePairingCode()
        let launchAtLoginState = startServices ? LaunchAtLoginController.currentState : .disabled
        pairingCode = initialCode
        trustedDeviceTokens = savedTokens
        pairingCodeText = initialCode
        pairedDeviceCount = savedTokens.count
        isAccessibilityGranted = startServices && inputController.isAccessibilityGranted
        isScreenCaptureGranted = startServices && screenStreamer.isScreenCaptureGranted
        isLaunchAtLoginEnabled = launchAtLoginState.isSelected
        launchAtLoginStatusText = launchAtLoginState.text
        if let savedDisplay = UserDefaults.standard.object(forKey: Self.selectedDisplayKey) as? NSNumber {
            preferredDisplayID = CGDirectDisplayID(savedDisplay.uint32Value)
        }
        persistsDeviceMetadata = startServices
        wantsServiceRunning = startServices
        if !startServices {
            statusText = "测试模式"
        } else if didRebuildTLSIdentity {
            statusText = "TLS 安全身份已重建，请在 iPad 重置信任"
            eventLog.record(statusText)
        } else if let tlsIdentityErrorText {
            statusText = tlsIdentityErrorText
        } else if let credentialStoreErrorText {
            statusText = credentialStoreErrorText
        }

        guard startServices else { return }
        hasPendingDisplayRecovery = virtualDisplayManager.hasPendingRecovery
        if hasPendingDisplayRecovery { statusText = "正在检查并恢复上次显示配置" }
        deviceNames = UserDefaults.standard.dictionary(forKey: "YingchuiTrustedDeviceNames") as? [String: String] ?? [:]
        publishTrustedDevices()
        virtualDisplayManager.onRestored = { [weak self] in
            Task { @MainActor [weak self] in self?.hasPendingDisplayRecovery = false }
        }
        virtualDisplayManager.onFailure = { [weak self] status in
            self?.networkQueue.async { [weak self] in
                self?.publishStatus(status)
                self?.publishStreamStatus(status, isStreaming: false)
            }
        }

        Task { @MainActor [weak self] in self?.refreshDisplays() }

        systemObserver = MacSystemObserver(
            onSleep: { [weak self] in
                Task { @MainActor [weak self] in self?.prepareForSystemSleep() }
            },
            onWake: { [weak self] in
                Task { @MainActor [weak self] in self?.resumeAfterSystemWake() }
            },
            onDisplaysChanged: { [weak self] in
                Task { @MainActor [weak self] in self?.refreshDisplays() }
            },
            onApplicationActive: { [weak self] in
                Task { @MainActor [weak self] in self?.refreshRuntimeState() }
            }
        )

        networkPathObserver.start(on: networkQueue) { [weak self] state in
            self?.handleNetworkPathUpdate(state)
        }

        networkQueue.async { [weak self] in
            self?.startOnNetworkQueue()
        }
    }

    deinit {
        displayTopologyWorkItem?.cancel()
        pairingTimer?.cancel()
        listener?.cancel()
        listenerRetryWorkItem?.cancel()
        networkPathObserver.stop()
        sessions.values.forEach {
            releaseInputState(for: $0)
            $0.cancel()
        }
        screenStreamer.stop()
        virtualDisplayManager.deactivate()
    }

    func publishSessionCount() {
        let count = sessions.count
        Task { @MainActor [weak self] in
            self?.connectedClientCount = count
        }
    }

    func publishPairedDeviceCount() {
        let count = trustedDeviceTokens.count
        Task { @MainActor [weak self] in
            self?.pairedDeviceCount = count
        }
    }

    func publishStatus(_ message: String) {
        eventLog.record(message)
        Task { @MainActor [weak self] in
            self?.statusText = message
        }
    }

    func publishStreamStatus(_ message: String, isStreaming: Bool) {
        let pending = virtualDisplayManager.hasPendingRecovery
        eventLog.record(message)
        Task { @MainActor [weak self] in
            self?.hasPendingDisplayRecovery = pending
            self?.streamStatusText = message
            self?.isStreaming = isStreaming
        }
    }

    func publishStopped() {
        eventLog.record("局域网服务已停止")
        Task { @MainActor [weak self] in
            self?.isRunning = false
            self?.statusText = "局域网服务已停止"
            self?.connectedClientCount = 0
            self?.portText = "—"
        }
    }

    func publishFailure(_ message: String) {
        eventLog.record(message)
        Task { @MainActor [weak self] in
            self?.isRunning = false
            self?.statusText = message
            self?.portText = "—"
        }
    }
}

enum HostSecurityError: LocalizedError {
    case randomGeneration(OSStatus)

    var errorDescription: String? {
        switch self {
        case .randomGeneration(let status):
            return "安全随机数生成失败（\(status)）"
        }
    }
}
