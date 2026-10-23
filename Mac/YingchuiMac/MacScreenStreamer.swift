import AVFoundation
import CoreMedia
import Foundation
import Network
import ScreenCaptureKit
import VideoToolbox
import YingchuiProtocol

struct EncodedVideoConfiguration: Sendable {
    let streamID: UUID
    let codec: VideoCodec
    let width: Int
    let height: Int
    let frameRate: Int
    let bitRate: Int
    let parameterSets: [Data]
    let videoKey: Data
}

struct SendableSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer
    let generation: UUID
}

final class EncodedFrameContext: @unchecked Sendable {
    let generation: UUID
    let ticket: UUID
    let submittedAt = DispatchTime.now().uptimeNanoseconds

    init(generation: UUID, ticket: UUID) {
        self.generation = generation
        self.ticket = ticket
    }
}

enum MacStreamStopCause: Sendable { case capture, startup, audio, transport, codec }

final class MacScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    typealias ConfigurationHandler = @Sendable (EncodedVideoConfiguration) -> Void
    typealias StatusHandler = @Sendable (String) -> Void
    typealias StoppedHandler = @Sendable (String, MacStreamStopCause) -> Void
    typealias StatisticsHandler = @Sendable (_ framesEncoded: UInt64, _ framesDropped: UInt64) -> Void

    let captureQueue = DispatchQueue(label: "com.yingchui.mac.capture", qos: .userInteractive)
    let eventLog = DiagnosticEventLog(
        subsystem: "com.yingchui.interconnect.mac",
        category: "屏幕回传"
    )
    let stateLock = StreamStateLock()
    var stream: SCStream?
    var captureRefreshTimer: DispatchSourceTimer?
    var captureRefreshInFlight = false
    var captureRecoveryPolicy = MacCaptureRecoveryPolicy()
    var receiverRequestedCaptureRefresh = false
    var captureRecoveryToken: UUID?
    var captureRecoveryTimeout: DispatchWorkItem?
    var compressionSession: VTCompressionSession?
    let audioSender = MacAudioSender()
    var capturesAudio = false
    var separatesCursor = false
    var udpConnection: NWConnection?
    var mediaPacketSink: USBMediaPacketSink?
    var receiverUsesWiFi = false

    var usesWirelessVideo: Bool { mediaPacketSink == nil && (receiverUsesWiFi || udpConnection?.currentPath?.usesInterfaceType(.wifi) == true) }
    var streamID = UUID()
    var videoCodec = VideoCodec.h264
    var h264FallbackFrameRate: Int?
    var consecutiveEncoderFailures = 0
    var encodeAdmission = VideoPipelineAdmission()
    var captureRevision: UInt64 = 0
    var submittedRevision: UInt64 = 0
    var lastImageCaptureUptime: UInt64 = 0
    var didApplyCaptureColorMetadata = false
    var encodeReplayWorkItem: DispatchWorkItem?
    var encodeReplayToken: UUID?
    var outputWidth = 0
    var outputHeight = 0
    var outputFrameRate = 60
    var outputBitRate = 8_000_000
    var bitRatePolicy = AdaptiveBitRatePolicy(maximumBitRate: 8_000_000)
    var frameID: UInt32 = 0
    var forceNextKeyFrame = true
    var startupTrace: StreamStartupTrace?
    var startupImageProbe = MacStartupImageProbe()
    var lastCaptureImage: CVPixelBuffer?
    var idleFramePolicy = MacIdleFramePolicy()
    var videoProgress = MacVideoProgress()
    var pipelineMetrics = MacVideoPipelineMetrics()
#if DEBUG
    var benchmarkMetrics = MacVideoBenchmarkMetrics()
    var benchmarkIdleTimer: DispatchSourceTimer?
    var benchmarkLastSubmission: UInt64 = 0
    var investigation = MacVideoInvestigationState()
#endif
    var lastParameterSets: [Data] = []
    var outstandingDatagrams = 0
    var repairCache = VideoRepairCache()
    lazy var datagramPacer = MacVideoDatagramPacer(queue: captureQueue)
    var framesEncoded: UInt64 = 0
    var framesDropped: UInt64 = 0
    var configurationHandler: ConfigurationHandler?
    var statusHandler: StatusHandler?
    var stoppedHandler: StoppedHandler?
    var statisticsHandler: StatisticsHandler?
    var videoKey = Data()
    var captureGeneration = UUID()
    var lastRuntimeErrorReportUptime: UInt64 = 0

    var isScreenCaptureGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    func requestScreenCaptureAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func start(
        startupTrace: StreamStartupTrace? = nil,
        destinationHost: NWEndpoint.Host,
        destinationPort: NWEndpoint.Port,
        audioPort: NWEndpoint.Port?,
        requestedWidth: Int,
        requestedHeight: Int,
        expectedSourceWidth: Int,
        expectedSourceHeight: Int,
        frameRate: Int,
        bitRate: Int,
        codec: VideoCodec = .h264,
        h264FallbackFrameRate: Int? = nil,
        receiverUsesWiFi: Bool? = nil,
        mediaPacketSink: USBMediaPacketSink? = nil,
        videoKey: Data,
        displayID: CGDirectDisplayID?,
        separatesCursor: Bool = false,
        onConfiguration: @escaping ConfigurationHandler,
        onStatus: @escaping StatusHandler,
        onStopped: @escaping StoppedHandler,
        onStatistics: @escaping StatisticsHandler
    ) {
        captureQueue.async { [weak self] in
            self?.startOnCaptureQueue(
                startupTrace: startupTrace,
                destinationHost: destinationHost,
                destinationPort: destinationPort,
                audioPort: audioPort,
                requestedWidth: requestedWidth,
                requestedHeight: requestedHeight,
                expectedSourceWidth: expectedSourceWidth,
                expectedSourceHeight: expectedSourceHeight,
                frameRate: frameRate,
                bitRate: bitRate,
                codec: codec,
                h264FallbackFrameRate: h264FallbackFrameRate,
                receiverUsesWiFi: receiverUsesWiFi,
                mediaPacketSink: mediaPacketSink,
                videoKey: videoKey,
                displayID: displayID,
                separatesCursor: separatesCursor,
                onConfiguration: onConfiguration,
                onStatus: onStatus,
                onStopped: onStopped,
                onStatistics: onStatistics
            )
        }
    }

    func startOnCaptureQueue(
        startupTrace: StreamStartupTrace?,
        destinationHost: NWEndpoint.Host,
        destinationPort: NWEndpoint.Port,
        audioPort: NWEndpoint.Port?,
        requestedWidth: Int,
        requestedHeight: Int,
        expectedSourceWidth: Int,
        expectedSourceHeight: Int,
        frameRate: Int,
        bitRate: Int,
        codec: VideoCodec = .h264,
        h264FallbackFrameRate: Int? = nil,
        receiverUsesWiFi: Bool? = nil,
        mediaPacketSink: USBMediaPacketSink? = nil,
        videoKey: Data,
        displayID: CGDirectDisplayID?,
        separatesCursor: Bool = false,
        onConfiguration: @escaping ConfigurationHandler,
        onStatus: @escaping StatusHandler,
        onStopped: @escaping StoppedHandler,
        onStatistics: @escaping StatisticsHandler
    ) {
        stopOnCaptureQueue()
#if DEBUG
        do {
            benchmarkMetrics.settings = try MacVideoBenchmarkSettings.load()
            investigation.settings = try MacVideoInvestigationSettings.load()
            encodeAdmission = VideoPipelineAdmission(
                maximumEncodes: benchmarkMetrics.settings?.maximumPendingEncodes ?? 1)
            datagramPacer.acceleratesLargeFrames = benchmarkMetrics.settings?.acceleratesLargeFrames ?? true
        } catch {
            onStopped("读取视频性能对比配置失败：\(error.localizedDescription)", .startup)
            return
        }
#endif
        self.startupTrace = startupTrace
        startupImageProbe = MacStartupImageProbe()
        let generation = UUID()
        stateLock.withLock {
            captureGeneration = generation
        }
        streamID = UUID()
        videoCodec = codec
        self.h264FallbackFrameRate = h264FallbackFrameRate
        let outputSize = VideoOutputSizingPolicy.normalizedRequest(
            StreamDimensions(width: requestedWidth, height: requestedHeight)
        )
        outputWidth = outputSize.width
        outputHeight = outputSize.height
        outputFrameRate = VideoStreamLimits.normalizedFrameRate(frameRate)
        outputBitRate = VideoStreamLimits.normalizedBitRate(bitRate)
        eventLog.record(
            "收到屏幕回传请求：采集显示器 \(displayID.map { String($0) } ?? "自动")，源画面 \(expectedSourceWidth)×\(expectedSourceHeight)，编码 \(outputWidth)×\(outputHeight)，\(outputFrameRate) fps，最高码率 \(outputBitRate) bps"
        )
        self.receiverUsesWiFi = receiverUsesWiFi == true
        self.mediaPacketSink = mediaPacketSink
        self.videoKey = videoKey
        self.separatesCursor = separatesCursor
        configurationHandler = onConfiguration
        statusHandler = onStatus
        stoppedHandler = onStopped
        statisticsHandler = onStatistics
        frameID = 0
        forceNextKeyFrame = true
        lastParameterSets = []
        framesEncoded = 0
        framesDropped = 0

        if mediaPacketSink == nil {
        let parameters = PeerNetworkTransport.video(host: destinationHost)
        let connection = NWConnection(host: destinationHost, port: destinationPort, using: parameters)
        udpConnection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.udpConnection === connection else { return }
            switch state {
            case .ready:
                self.statusHandler?("UDP 视频通道已就绪")
                if let path = connection.currentPath {
                    self.eventLog.record("视频发送路径：\(PeerNetworkTransport.routeDescription(path))，分批发送 \(self.usesWirelessVideo ? "启用" : "未启用")")
                }
            case .failed(let error):
                self.stoppedHandler?("UDP 视频通道失败：\(error.localizedDescription)", .transport)
                self.stopOnCaptureQueue()
            case .waiting(let error):
                self.statusHandler?("UDP 视频通道等待网络：\(error.localizedDescription)")
            default:
                break
            }
        }
        connection.start(queue: captureQueue)
        } else { eventLog.record("视频发送路径：USB，复用已认证控制会话对应的有线通道") }
        capturesAudio = audioPort != nil
        if let audioPort {
            audioSender.start(host: destinationHost, port: audioPort, streamID: streamID, key: videoKey,
                              queue: captureQueue, packetSink: mediaPacketSink) { [weak self] status in
                guard let self else { return }
                self.stoppedHandler?(status, .audio)
                self.stopOnCaptureQueue()
            }
        }

        let expectedSourceSize = VideoOutputSizingPolicy.normalizedRequest(
            StreamDimensions(width: expectedSourceWidth, height: expectedSourceHeight)
        )
        Task { [weak self] in
            await self?.startCapture(
                displayID: displayID,
                expectedSourceSize: expectedSourceSize,
                generation: generation
            )
        }
    }

    func stop() {
        captureQueue.async { [weak self] in
            self?.stopOnCaptureQueue()
        }
    }

    func stopOnCaptureQueue() {
#if DEBUG
        benchmarkIdleTimer?.cancel()
        benchmarkIdleTimer = nil
        benchmarkLastSubmission = 0
#endif
        encodeReplayWorkItem?.cancel()
        encodeReplayWorkItem = nil
        encodeReplayToken = nil
        encodeAdmission.reset()
        captureRevision = 0
        submittedRevision = 0
        lastImageCaptureUptime = 0
        didApplyCaptureColorMetadata = false
        consecutiveEncoderFailures = 0
        datagramPacer.cancel()
        repairCache.reset()
        captureRefreshTimer?.cancel()
        captureRefreshTimer = nil
        captureRefreshInFlight = false
        captureRecoveryPolicy = MacCaptureRecoveryPolicy()
        receiverRequestedCaptureRefresh = false
        captureRecoveryToken = nil
        captureRecoveryTimeout?.cancel()
        captureRecoveryTimeout = nil
        lastCaptureImage = nil
        idleFramePolicy = MacIdleFramePolicy()
        audioSender.stop()
        capturesAudio = false
        let activeStream = stream
        stream = nil
        if activeStream != nil || compressionSession != nil || udpConnection != nil {
            eventLog.record("停止前视频链路：流 \(streamID)，\(videoProgress.summary())，已发送帧 \(framesEncoded)，丢帧 \(framesDropped)")
            eventLog.record("正在停止当前屏幕采集、编码和音视频通道")
        }
        if let activeStream {
            Task { [weak self] in
                do {
                    try await activeStream.stopCapture()
                } catch {
                    self?.captureQueue.async { [weak self] in
                        self?.reportRuntimeError("停止屏幕采集失败：\(error.localizedDescription)")
                    }
                }
            }
        }
        if let compressionSession {
            VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(compressionSession)
        }
        compressionSession = nil
        udpConnection?.stateUpdateHandler = nil
        udpConnection?.cancel()
        udpConnection = nil
        mediaPacketSink = nil
        stateLock.withLock {
            outstandingDatagrams = 0
            captureGeneration = UUID()
        }
        videoProgress = MacVideoProgress()
        pipelineMetrics = MacVideoPipelineMetrics()
#if DEBUG
        benchmarkMetrics = MacVideoBenchmarkMetrics()
        investigation = MacVideoInvestigationState()
#endif
    }

    func requestKeyFrame(reportProgress: Bool = false) {
        stateLock.withLock {
            forceNextKeyFrame = true
        }
        if reportProgress {
            let generation = stateLock.withLock { captureGeneration }
            captureQueue.async { [weak self] in
                guard let self, self.stateLock.withLock({ self.captureGeneration == generation }) else { return }
                // 静止采集可能不再回调；请求真实的新采集帧，不重复旧像素伪造进展。
                if self.stream != nil, self.videoProgress.captureStatus == "画面静止" {
                    self.receiverRequestedCaptureRefresh = true
                }
                self.eventLog.recordPeriodic(
                    "收到关键帧补发请求：流 \(self.streamID)，\(self.videoProgress.summary())，已发送帧 \(self.framesEncoded)，待发送包 \(self.stateLock.withLock { self.outstandingDatagrams })",
                    key: "关键帧链路诊断", intervalNanoseconds: 2_000_000_000)
            }
        }
    }

    func adaptBitRate(lossRate: Double) {
        captureQueue.async { [weak self] in
            guard let self, let compressionSession = self.compressionSession else { return }
#if DEBUG
            if self.benchmarkMetrics.settings != nil { return }
#endif
            guard let nextBitRate = self.bitRatePolicy.evaluate(lossRate: lossRate) else { return }
            let status = VTSessionSetProperty(
                compressionSession,
                key: kVTCompressionPropertyKey_AverageBitRate,
                value: nextBitRate as CFNumber
            )
            guard status == noErr else {
                self.bitRatePolicy.restore(currentBitRate: self.outputBitRate)
                self.statusHandler?("编码码率调整失败（\(status)）")
                return
            }
            self.outputBitRate = nextBitRate
            // 修改码率不破坏参考链；真正丢帧时由接收端请求关键帧，避免降码率又制造突发。
            self.statusHandler?("自适应码率 \(String(format: "%.1f", Double(nextBitRate) / 1_000_000)) Mbps，接收丢帧率 \(String(format: "%.1f", lossRate * 100))%")
        }
    }

}

enum StreamerError: LocalizedError {
    case compressionSession(OSStatus)
    case compressionProperty(String, OSStatus)
    case invalidDisplayScale
    case requestedDisplayUnavailable
    case shareableContentUnavailable(String)
    case captureSuperseded

    var errorDescription: String? {
        switch self {
        case .compressionSession(let status):
            return "视频编码器初始化失败（\(status)）"
        case .compressionProperty(let key, let status):
            return "视频编码器属性设置失败（\(key)，\(status)）"
        case .invalidDisplayScale:
            return "无法读取显示器原生像素比例"
        case .requestedDisplayUnavailable:
            return "Mac 镜像画面尚未以 iPad 原生分辨率就绪"
        case .shareableContentUnavailable(let detail):
            return "Mac 屏幕采集列表暂不可用：\(detail)"
        case .captureSuperseded:
            return "屏幕采集请求已被新的请求替换"
        }
    }
}

final class StreamStateLock {
    private let underlying = NSLock()
    func withLock<T>(_ body: () -> T) -> T {
        underlying.lock()
        defer { underlying.unlock() }
        return body()
    }
}
