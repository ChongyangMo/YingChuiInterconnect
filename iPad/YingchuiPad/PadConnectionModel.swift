import Combine
import CryptoKit
import Foundation
import Network
import Security
import UIKit
import YingchuiProtocol

struct DiscoveredHost: Identifiable, Hashable {
    let endpoint: NWEndpoint
    let name: String
    let hostID: String

    var id: String { hostID }
    var endpointDescription: String { endpoint.debugDescription }
}

struct PendingPing: Sendable {
    let uptimeNanoseconds: UInt64
    let wallClockMilliseconds: UInt64
}

struct PendingVisualControl: Sendable {
    let sentAtUptimeNanoseconds: UInt64
    let executedAtMacMicroseconds: UInt64
}

final class PadConnectionModel: ObservableObject, @unchecked Sendable {
    @Published var discoveredHosts: [DiscoveredHost] = []
    @Published var lastHostID = UserDefaults.standard.string(forKey: "YingchuiLastHostID")
    @Published var lastHostName = UserDefaults.standard.string(forKey: "YingchuiLastHostName")
    @Published var shouldPresentFullScreen = false
    @Published var videoIsPlaying = false
    @Published var enterFullScreenAfterConnection = false
    @Published var transferStatus = ""
    @Published var isAudioEnabled = UserDefaults.standard.object(forKey: "YingchuiAudioEnabled") as? Bool ?? true
    @Published var discoveryStatus = "正在查找 Mac"
    @Published var statusText = "正在查找附近的 Mac"
    @Published var connectedHostName: String?
    @Published var isConnected = false
    @Published var supportsDirectTouch = false
    @Published var supportsTouchHover = false
    @Published var isPaired = false
    @Published var remoteKeyboardLanguage: RemoteKeyboardLanguage = .english
    @Published var keyboardLanguageChanging = false
    @Published var isPairing = false
    @Published var canResetCurrentHostTrust = false
    @Published var requiresAllTrustReset = false
    @Published var pairingMessage = "连接后请输入 Mac 上显示的六位配对码"
    @Published var selectedDisplayMode: RemoteDisplayMode = {
        let saved = UserDefaults.standard.string(forKey: "YingchuiDisplayMode")
        return saved == RemoteDisplayMode.extended.rawValue ? .extended : .mirror
    }()
    @Published var displayPlacement = RemoteDisplayPlacement(rawValue:
        UserDefaults.standard.string(forKey: "YingchuiDisplayPlacement") ?? "right") ?? .right
    @Published var activeDisplayState: RemoteDisplayState?
    @Published var displayModeChanging = false
    @Published var isStreaming = false
    @Published var streamStatusText = "屏幕回传尚未启动"
    @Published var videoResolutionText = "—"
    @Published var videoAspectRatio: Double?
    @Published var activeQuality: StreamQualityPreset = .native
    @Published var resolutionOptions: [StreamQualityPreset] = []
    @Published var resolutionViewport: StreamDimensions?
    @Published var selectedQuality: StreamQualityPreset = .native {
        didSet {
            UserDefaults.standard.set(selectedQuality.rawValue, forKey: Self.selectedQualityKey)
        }
    }

    let videoRenderer: VideoRenderer
    @MainActor let streamMetrics = PadStreamMetrics()
    @MainActor let telemetry = PadConnectionTelemetry()

    static let deviceIDKey = "YingchuiPadDeviceID"
    static let selectedQualityKey = "YingchuiPadSelectedQuality"
    static let selectedQualityVersionKey = "YingchuiPadSelectedQualityVersion"

    @MainActor weak var linkedAccount: AccountModel?
    var hostSupportsAccountLink = false
    var accountLinkAuthorized = false
    var accountLinkLease: AccountLinkLease?
    let networkQueue = DispatchQueue(label: "com.yingchui.pad.network")
    var controlPipelineMetrics = PadControlPipelineMetrics()
    let eventLog = DiagnosticEventLog(
        subsystem: "com.yingchui.interconnect.pad",
        category: "连接"
    )
    let networkPathObserver = LocalNetworkPathObserver()
    let deviceID: String
    let localDeviceName: String
    var browser: NWBrowser?
    var discoveryPausedForConnection = false
    var resumeDiscoveryOnDisconnect = false
    var connection: NWConnection?
    var decoder = WireMessageDecoder()
    var pendingPings: [UUID: PendingPing] = [:]
    var peerClockEstimator = PeerClockEstimator()
    let peerClockEstimateState = SynchronizedValue<PeerClockEstimate?>(nil)
    var controlAcknowledgements = ControlAcknowledgementTracker()
    var didReportControlAcknowledgementTimeout = false
    let latestControlRoundTripState = SynchronizedValue<Double?>(nil)
    var pingTimer: DispatchSourceTimer?
    let audioReceiver = PadAudioReceiver()
    let audioRequested = SynchronizedValue(false)
    let videoDecodeCapabilities = SynchronizedValue<[VideoDecodeCapability]>([])
    let requestedVideoCapabilities = SynchronizedValue<[VideoDecodeCapability]>([])
    let activeVideoCodec = SynchronizedValue(VideoCodec.h264)
    let hevcDisabled = SynchronizedValue(false)
    var peerMinimumProtocolVersion: Int?
    var wireVersion = YingchuiService.protocolVersion
    var activeAudioPort: UInt16?
    let receiverPreparationStarted = SynchronizedValue<UInt64?>(nil)
    let videoStartupTrace = SynchronizedValue<StreamStartupTrace?>(nil)
    let videoReceiver = PadVideoReceiver()
    let playbackStatistics = PadPlaybackStatistics()
    let activeStreamIDState = SynchronizedValue<UUID?>(nil)
    var activeStreamID: UUID? {
        get { activeStreamIDState.value }
        set { activeStreamIDState.set(newValue) }
    }
    let connectionSelection = SynchronizedValue(UUID())
    let connectionEpoch = SynchronizedValue(UUID())
    let videoReceiverGeneration = SynchronizedValue<UUID?>(nil)
    let videoRequestID = SynchronizedValue<UUID?>(nil)
    private let videoConfigurationPendingState = SynchronizedValue(false)
    var videoConfigurationPending: Bool {
        get { videoConfigurationPendingState.value }
        set { videoConfigurationPendingState.set(newValue) }
    }
    var requestedDisplayConfiguration: StreamRequest?
    var videoConfigurationDeadline: DispatchWorkItem?
    var connectionDeadlineWorkItem: DispatchWorkItem?
    var connectionPhase: PadConnectionPhase?
    var pendingHelloID: UUID?
    let connectedHostKeyState = SynchronizedValue<String?>(nil)
    var connectedHostKey: String? {
        get { connectedHostKeyState.value }
        set { connectedHostKeyState.set(newValue) }
    }
    let trustStore: PadTrustStore
    var pendingLegacyCredential: HostCredential?
    var credentialStoreErrorText: String?
    var pendingTextIDs: Set<UUID> = []
    var pendingKeyboardLanguageRequest: UUID?
    var requestedKeyboardLanguage: RemoteKeyboardLanguage?
    var keyboardLanguageTimeout: DispatchWorkItem?
    var pendingClipboardRequest: (id: UUID, kind: WireMessageKind)?
    var pendingPairRequestID: UUID?
    var pendingCertificateFingerprint: String?
    var pendingConnectionFailureReason: String?
    var desiredEndpoint: NWEndpoint?
    var usbService: PadUSBService?
    var usbDiscoveredHosts: [UUID: DiscoveredHost] = [:]
    var networkDiscoveredHosts: [DiscoveredHost] = []
    var reconnectAttempt = 0
    var reconnectWorkItem: DispatchWorkItem?
    var connectionRouteFallbackWorkItem: DispatchWorkItem?
    var connectionAllowsPeerToPeer = false
    let isInBackgroundState = SynchronizedValue(false)
    var lastNetworkState: LocalNetworkState?
    let clockOffsetState = SynchronizedValue<Double?>(nil)
    var clockOffsetMilliseconds: Double? {
        get { clockOffsetState.value }
        set { clockOffsetState.set(newValue) }
    }
    let wantsStreamingState = SynchronizedValue(false)
    var wantsStreaming: Bool {
        get { wantsStreamingState.value }
        set { wantsStreamingState.set(newValue) }
    }
    let pendingVisualControlState = SynchronizedValue<PendingVisualControl?>(nil)
    var pendingCursorInput: RemoteCursorInput?
    var pendingCursorStreamID: UUID?
    var pendingPointerX = 0.0
    var pendingPointerY = 0.0
    var pointerFlushID: UUID?
    var viewport = StreamDimensions(width: 1_920, height: 1_080)
    var maximumDisplayFrameRate = 60
    let streamRequestState = SynchronizedValue(
        StreamRequest(
            quality: .native,
            viewport: StreamDimensions(width: 1_920, height: 1_080)
        )
    )
    var streamRequest: StreamRequest {
        get { streamRequestState.value }
        set { streamRequestState.set(newValue) }
    }
    var activeVideoPort: UInt16?
    var streamReconfigureWorkItem: DispatchWorkItem?
    var streamRecoveryWorkItem: DispatchWorkItem?
    var streamRecoveryPolicy = StreamRecoveryPolicy()
    var previousStatistics: (packets: UInt64, assembled: UInt64, completed: UInt64, dropped: UInt64)?
    var videoStallPolicy = PadVideoStallPolicy()
    var lastVideoStatisticsUptime: UInt64?
    var roundTripSamples = LatencySampleWindow(capacity: 300)
    var controlRoundTripSamples = LatencySampleWindow(capacity: 600)
    var interactionToVideoFrameSamples = LatencySampleWindow(capacity: 600)
    var latestInteractionToVideoFrameMilliseconds: Double?
    var latestVideoLatencyMilliseconds: Double?
    var videoLatencySamples = LatencySampleWindow(capacity: 600)

    @MainActor
    init(startServices: Bool = NSClassFromString("XCTestCase") == nil, trustStore: PadTrustStore = PadTrustStore()) {
        self.trustStore = trustStore
        videoRenderer = VideoRenderer()
        if UserDefaults.standard.integer(forKey: Self.selectedQualityVersionKey) < 2 {
            selectedQuality = .native
            UserDefaults.standard.set(StreamQualityPreset.native.rawValue, forKey: Self.selectedQualityKey)
            UserDefaults.standard.set(2, forKey: Self.selectedQualityVersionKey)
        } else if let rawQuality = UserDefaults.standard.string(forKey: Self.selectedQualityKey),
           let savedQuality = StreamQualityPreset(rawValue: rawQuality) {
            selectedQuality = savedQuality
        }
        if startServices {
            do {
                try trustStore.load()
            } catch {
                requiresAllTrustReset = true
                credentialStoreErrorText = "配对凭据读取失败：\(error.localizedDescription)"
                statusText = credentialStoreErrorText ?? "配对凭据读取失败"
                pairingMessage = "无法读取完整的配对信息，请重置信任"
            }
        }
        if let savedID = UserDefaults.standard.string(forKey: Self.deviceIDKey) {
            deviceID = savedID
        } else {
            let newID = UUID().uuidString
            UserDefaults.standard.set(newID, forKey: Self.deviceIDKey)
            deviceID = newID
        }
        localDeviceName = UIDevice.current.name

        videoRenderer.cursor.onDiagnostic = { [weak self] in self?.eventLog.record($0) }
        configureReceiverCallbacks()

        guard startServices else { statusText = "测试模式"; return }
        networkPathObserver.start(on: networkQueue) { [weak self] state in
            self?.handleNetworkPathUpdate(state)
        }
        networkQueue.async { [weak self] in
            self?.configureUSBService()
            self?.startBrowsingOnNetworkQueue()
        }
    }

    deinit {
        connectionDeadlineWorkItem?.cancel()
        browser?.cancel()
        connection?.cancel()
        pingTimer?.cancel()
        reconnectWorkItem?.cancel()
        connectionRouteFallbackWorkItem?.cancel()
        streamReconfigureWorkItem?.cancel()
        streamRecoveryWorkItem?.cancel()
        networkPathObserver.stop()
        audioReceiver.stop()
        activeAudioPort = nil
        videoReceiver.stop()
    }

    @MainActor
    func recordFullScreenLayout(
        containerSize: CGSize,
        streamViewportSize: CGSize,
        nativeScale: CGFloat
    ) {
        let message = String(
            format: "全屏布局：容器 %.0f×%.0f，回传视口 %.0f×%.0f，像素倍率 %.2f，屏幕上限 %d Hz",
            containerSize.width,
            containerSize.height,
            streamViewportSize.width,
            streamViewportSize.height,
            nativeScale,
            maximumDisplayFrameRate
        )
        eventLog.record(message)
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--layout-smoke-test") {
            print("模拟器布局测试：\(message)")
        } else if ProcessInfo.processInfo.arguments.contains("--physical-smoke-test") {
            print("实机自动测试：\(message)")
        }
#endif
    }

    @MainActor
    var diagnosticSummary: String {
        let audio = audioReceiver.playbackStatistics
        return """
        鹰锤互联诊断
        Mac：\(connectedHostName ?? "未连接")
        状态：\(statusText)
        分辨率：\(resolutionText(for: selectedQuality) ?? "不可用")
        视频：\(videoResolutionText)
        RTT 当前/P95：\(Self.format(roundTripMilliseconds)) / \(Self.format(roundTripP95Milliseconds))
        控制执行 当前/P95：\(Self.format(controlRoundTripMilliseconds)) / \(Self.format(controlRoundTripP95Milliseconds))
        输入至后续帧 当前/P95：\(Self.format(interactionToVideoFrameMilliseconds)) / \(Self.format(interactionToVideoFrameP95Milliseconds))
        画面延迟 当前/P50/P95：\(Self.format(estimatedVideoLatencyMilliseconds)) / \(Self.format(videoLatencyP50Milliseconds)) / \(Self.format(videoLatencyP95Milliseconds))
        UDP 包：\(videoPacketsReceived)
        解码帧：\(videoFramesDecoded)
        丢帧：\(videoFramesDropped)
        声音渲染采样帧：\(audio.renderedFrames)
        声音待渲染：\(Self.format(audio.bufferedMilliseconds))
        最近事件：
        \(eventLog.recentSummary())
        声音事件：
        \(audioReceiver.diagnosticSummary)
        """
    }

    func publishStatus(_ status: String) {
        eventLog.record(status)
        Task { @MainActor [weak self] in
            self?.statusText = status
        }
    }

    static func format(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f ms", value)
    }
}
