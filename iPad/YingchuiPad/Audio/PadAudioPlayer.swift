import AVFoundation
import YingchuiProtocol

final class PadAudioPlayer: @unchecked Sendable {
    var onFailure: (@Sendable (String) -> Void)?
    var onRendered: (@Sendable () -> Void)?
    private let queue = DispatchQueue(label: "com.yingchui.pad.audio-playback", qos: .userInteractive)
    private let submissionLock = NSLock()
    private let budget = PadAudioBufferBudget()
    private let engine: AVAudioEngine
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var latencyController = PadAudioLatencyController()
    private var format: AVAudioFormat?
    private var started = false
    private var sessionActive = false
    private var latencyTimer: DispatchSourceTimer?
    private var recoveryStartedAt: UInt64?
    private var recoveryPeakMilliseconds = 0
    private var lastRateLogUptime: UInt64?
    private let log = DiagnosticEventLog(subsystem: "com.yingchui.interconnect.pad", category: "声音播放")
    private var observers: [NSObjectProtocol] = []
    var statistics: PadAudioBufferStatistics { budget.statistics }
    var diagnosticSummary: String { log.recentSummary(limit: 20) }

    init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
        engine.attach(player)
        engine.attach(timePitch)
        timePitch.pitch = 0
        for name in [Notification.Name.AVAudioEngineConfigurationChange,
                     AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                guard let self else { return }
                if notification.name == .AVAudioEngineConfigurationChange,
                   notification.object as AnyObject? !== self.engine { return }
                let detail = notification.userInfo?.description ?? "无附加信息"
                self.log.record("声音设备事件：\(name.rawValue)，\(detail)")
            })
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver); stopOnQueue() }

    /// 在公布接收端口之前完成声音设备初始化，避免冷启动耗时挤占播放缓冲。
    func prepare(onReady: @escaping @Sendable () -> Void) {
        submissionLock.withLock {
            let generation = budget.generation
            queue.async { [weak self] in
                guard let self, self.budget.isActive(generation) else { return }
                do {
                    try self.ensureEngineRunning()
                    guard self.budget.isActive(generation) else { return }
                    self.log.record("声音播放设备已就绪，开始接收回传")
                    onReady()
                } catch {
                    self.submissionLock.withLock { self.failOnSubmissionLock(error, generation: generation) }
                }
            }
        }
    }

    /// 更换流时清空旧缓冲，保留已初始化的设备；旧渲染回调不能影响新流。
    func resetStream() {
        submissionLock.withLock {
            budget.reset()
            queue.async { [weak self] in
                guard let self else { return }
                self.player.stop()
                self.resetLatencyControl()
            }
        }
    }

    func enqueue(_ packet: AudioPacket) {
        submissionLock.withLock {
            let generation = budget.generation
            do {
                guard packet.pcm.count % 4 == 0 else { throw AudioPacketError.invalidPacket }
                // 先预留容量，再进入播放队列，冷启动期间也不能无限堆积任务。
                let ticket = try budget.reserve(frames: packet.frameCount, generation: generation)
                queue.async { [weak self] in self?.schedule(packet, ticket: ticket) }
            } catch { failOnSubmissionLock(error, generation: generation) }
        }
    }

    func stop() {
        submissionLock.withLock {
            // 立即使旧任务、旧回调失效；清理任务一定排在下一轮提交之前。
            budget.reset()
            queue.async { [weak self] in self?.stopOnQueue() }
        }
    }

    private func schedule(_ packet: AudioPacket, ticket: PadAudioBufferTicket) {
        guard budget.isActive(ticket.generation) else { return }
        do {
            try ensureEngineRunning()
            guard budget.isActive(ticket.generation) else { return }
            updatePlaybackLatency()
            guard let format,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(packet.frameCount)),
                  let planes = buffer.floatChannelData else { throw AudioPacketError.unsupportedFormat }
            buffer.frameLength = AVAudioFrameCount(packet.frameCount)
            packet.pcm.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                for frame in 0..<packet.frameCount {
                    for channel in 0..<2 {
                        let index = frame * 4 + channel * 2
                        let sample = Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
                        planes[channel][frame] = Float(sample) / 32_768
                    }
                }
            }
            player.scheduleBuffer(buffer, completionCallbackType: .dataRendered) { [weak self] _ in
                guard let self, self.budget.rendered(ticket) else { return }
                self.onRendered?()
            }
            // 首个缓冲提交后再播放，避免先运行空播放节点。
            if !player.isPlaying { player.play() }
        } catch {
            submissionLock.withLock { failOnSubmissionLock(error, generation: ticket.generation) }
        }
    }

    private func ensureEngineRunning() throws {
        if !started {
            try startEngine()
        } else if !engine.isRunning {
            // 系统重新配置音频设备后，started 标记可能仍为真，实际引擎却已停止。
            log.record("声音播放引擎已停止，正在重新启动声音设备")
            try engine.start()
            log.record("声音播放引擎已重新启动")
        }
        guard engine.isRunning else { throw PadAudioPlaybackError.engineStopped }
    }

    private func startEngine() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setPreferredSampleRate(Double(AudioPacketCodec.sampleRate))
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
        sessionActive = true
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(AudioPacketCodec.sampleRate), channels: 2) else {
            throw AudioPacketError.unsupportedFormat
        }
        self.format = format
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        try engine.start()
        started = true
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.updatePlaybackLatency() }
        latencyTimer = timer
        timer.resume()
    }

    /// 不依赖新包到达也能恢复原速，避免整批声音排队后一直保持加速。
    private func updatePlaybackLatency() {
        guard started, budget.isActive(budget.generation) else { return }
        let snapshot = budget.statistics
        let buffered = snapshot.bufferedMilliseconds
        let now = DispatchTime.now().uptimeNanoseconds
        if buffered > Double(AudioBufferingPolicy.recoveryThresholdMilliseconds), recoveryStartedAt == nil {
            recoveryStartedAt = now
            log.record("声音网络突发积压：待播放 \(Int(buffered)) 毫秒，最大接收间隔 \(snapshot.longestReceiveGapNanoseconds / 1_000_000) 毫秒，开始保留采样并加速恢复")
        }
        if let began = recoveryStartedAt {
            recoveryPeakMilliseconds = max(recoveryPeakMilliseconds, Int(buffered))
            if buffered <= Double(AudioBufferingPolicy.settledMilliseconds) {
                log.record("声音突发积压已消化：峰值 \(recoveryPeakMilliseconds) 毫秒，恢复用时 \((now - min(now, began)) / 1_000_000) 毫秒，当前 \(Int(buffered)) 毫秒")
                recoveryStartedAt = nil
                recoveryPeakMilliseconds = 0
            }
        }
        if let rate = latencyController.update(bufferedMilliseconds: buffered, now: now) {
            timePitch.rate = rate
            if lastRateLogUptime.map({ now - min(now, $0) >= 2_000_000_000 }) ?? true {
                lastRateLogUptime = now
                log.record("声音缓冲调节：待播放 \(Int(buffered)) 毫秒，播放速度 \(rate)，音高保持不变")
            }
        }
    }

    private func resetLatencyControl() {
        latencyController.reset()
        timePitch.rate = 1
        recoveryStartedAt = nil
        recoveryPeakMilliseconds = 0
        lastRateLogUptime = nil
    }

    private func failOnSubmissionLock(_ error: Error, generation: UUID) {
        guard budget.fail(generation) else { return }
        let snapshot = budget.statistics
        let now = DispatchTime.now().uptimeNanoseconds
        let renderGap = snapshot.lastRenderedUptime.map { "\((now - min(now, $0)) / 1_000_000) 毫秒" } ?? "尚无渲染"
        let message = "声音播放失败：\(error.localizedDescription)，已接收 \(snapshot.receivedFrames)／已渲染 \(snapshot.renderedFrames) 采样帧，积压 \(snapshot.bufferedPackets) 包，距上次渲染 \(renderGap)，最大接收间隔 \(snapshot.longestReceiveGapNanoseconds / 1_000_000) 毫秒"
        log.record(message)
        queue.async { [weak self] in
            guard let self, self.budget.isFailed(generation) else { return }
            self.log.record("声音故障现场：引擎运行 \(self.engine.isRunning)，播放节点运行 \(self.player.isPlaying)，故障处理等待 \((DispatchTime.now().uptimeNanoseconds - now) / 1_000_000) 毫秒")
            self.stopOnQueue()
            self.onFailure?(message)
        }
    }

    private func stopOnQueue() {
        latencyTimer?.cancel()
        latencyTimer = nil
        player.stop()
        engine.stop()
        resetLatencyControl()
        if sessionActive {
            do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
            catch { onFailure?("释放声音设备失败：\(error.localizedDescription)") }
        }
        sessionActive = false
        started = false
    }
}
