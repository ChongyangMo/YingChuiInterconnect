import Foundation
import Network
import YingchuiProtocol

final class PadVideoReceiver: @unchecked Sendable {
    typealias PortHandler = @Sendable (UInt16, UUID) -> Void
    typealias FrameHandler = @Sendable (CompletedVideoFrame, PadFrameReceiveTiming?) -> Void
    typealias StatusHandler = @Sendable (String) -> Void
    typealias StatisticsHandler = @Sendable (PadVideoReceiveSnapshot) -> Void

    var onReady: PortHandler?
    var onFrame: FrameHandler?
    var onStatus: StatusHandler?
    var onStatistics: StatisticsHandler?
    var onNeedsKeyFrame: (@Sendable () -> Void)?
    var onNeedsVideoRepair: (@Sendable (UUID, VideoRepairRequest) -> Void)?
    var supportsVideoRepair = false
    var pendingRepair: (frameID: UInt32, requestedAt: UInt64, deadline: UInt64)?
    var repairTimingPolicy = AdaptiveVideoRepairPolicy()
    var repairWaitNanoseconds: UInt64 = 90_000_000
    private var receiveTiming = PadFrameReceiveTimingTracker()
#if DEBUG
    private var repairProbe = PadVideoRepairProbe()
#endif
    var onRecoverableFailure: StatusHandler?

    let queue = DispatchQueue(label: "com.yingchui.pad.video", qos: .userInteractive)
    let eventLog = DiagnosticEventLog(
        subsystem: "com.yingchui.interconnect.pad",
        category: "视频接收"
    )
    private var listener: NWListener?
    private var connection: NWConnection?
    private weak var receivingConnection: NWConnection?
    private var candidates: [UUID: NWConnection] = [:]
    private var startupBuffer = PadVideoStartupBuffer()
    private var statisticsTimer: DispatchSourceTimer?
    var reassembler = VideoFrameDeliveryBuffer(maximumPendingFrames: 6)
    var reorderWakeup: DispatchWorkItem?
    var reorderGeneration = UUID()
    var reorderDeadline: UInt64?
    var expectedStreamID: UUID?
    var receiverGeneration: UUID?
    private var videoKey: Data?
    var awaitingRecoveryKeyFrame = false
    private var lastCompletedFrameID: UInt32?
    private var packetsReceived: UInt64 = 0
    private var framesCompleted: UInt64 = 0
    var framesDropped: UInt64 = 0
    private var networkFramesMissing: UInt64 = 0
    private var lastKeyFrameRequestUptime: UInt64 = 0
    private var lastCompletedFrameUptime: UInt64 = 0
    private var lastDecodeErrorReportUptime: UInt64 = 0
    private var didLogFirstDatagram = false
    private var didReportInitialKeyFrameWait = false
    private var didLogFirstFrame = false
    private var receiveDiagnostics = PadVideoReceiveDiagnostics()
    private var pipelineMetrics = PadReceivePipelineMetrics()
    private var usbPending: [(at: UInt64, data: Data)] = []
    private var usbPendingBytes = 0
    private var loggedUSB = false

    func receiveUSB(_ data: Data, generation: UUID) {
        queue.async { [weak self] in
            guard let self, self.receiverGeneration == generation else { return }
            guard self.videoKey != nil, self.expectedStreamID != nil else {
                let now = DispatchTime.now().uptimeNanoseconds
                while let first = self.usbPending.first, now - first.at > 250_000_000 {
                    self.usbPendingBytes -= first.data.count; self.usbPending.removeFirst()
                }
                guard self.usbPendingBytes + data.count <= 1_048_576, self.usbPending.count < 1_024 else {
                    self.failAndStop("USB 视频启动数据超过暂存限制"); return
                }
                self.usbPending.append((now, data)); self.usbPendingBytes += data.count
                return
            }
            if !self.loggedUSB { self.loggedUSB = true; self.eventLog.record("视频接收路径：USB，验证现有视频密钥和流标识") }
            self.handle(data)
        }
    }

    func start(generation: UUID = UUID()) {
        queue.async { [weak self] in
            self?.startOnQueue(generation: generation)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    /// 请求新流前重新进入有界认证暂存阶段；画面仍由渲染器保留。
    func prepareForConfiguration(completion: @escaping @Sendable () -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.connection?.stateUpdateHandler = nil
            self.connection?.cancel()
            self.connection = nil
            for id in Array(self.candidates.keys) { self.rejectCandidate(id) }
            self.startupBuffer.reset()
            self.expectedStreamID = nil
            self.videoKey = nil
            self.resetDeliveryBuffer()
            self.lastCompletedFrameID = nil
            self.awaitingRecoveryKeyFrame = false
            completion()
        }
    }

    func expect(streamID: UUID, videoKey: Data, supportsRepair: Bool = false) {
        queue.async { [weak self] in
            self?.eventLog.record("收到视频配置：流 \(streamID.uuidString)，密钥长度 \(videoKey.count)")
            if self?.expectedStreamID != streamID {
                self?.connection?.stateUpdateHandler = nil
                self?.connection?.cancel()
                self?.connection = nil
            }
            self?.expectedStreamID = streamID
            self?.videoKey = videoKey
            self?.supportsVideoRepair = supportsRepair
            self?.lastCompletedFrameID = nil
            self?.awaitingRecoveryKeyFrame = false
            self?.resetDeliveryBuffer()
            self?.lastCompletedFrameUptime = DispatchTime.now().uptimeNanoseconds
            self?.didReportInitialKeyFrameWait = false
            self?.didLogFirstDatagram = false
            self?.didLogFirstFrame = false
            guard let self else { return }
            let usbPackets = self.usbPending
            self.usbPending = []; self.usbPendingBytes = 0
            let now = DispatchTime.now().uptimeNanoseconds
            for packet in usbPackets where now - packet.at <= 250_000_000 { self.handle(packet.data) }
            for (id, candidate) in self.candidates {
                let packets = self.startupBuffer.take(id)
                if !packets.isEmpty {
                    self.eventLog.record("视频配置已就绪，正在认证暂存的 \(packets.count) 个启动数据包")
                }
                for packet in packets {
                    self.processCandidatePacket(packet, candidate: candidate, id: id)
                }
            }
        }
    }

    private func startOnQueue(generation: UUID) {
        stopOnQueue()
        receiverGeneration = generation
        eventLog.record("正在启动 UDP 视频接收端")
        do {
            let parameters = PeerNetworkTransport.video()
            (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.shouldCalculateReceiveTime = true
            parameters.serviceClass = .interactiveVideo
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else {
                        self.failAndStop("UDP 监听端口不可用")
                        return
                    }
                    self.eventLog.record("UDP 视频接收端已就绪：端口 \(port)")
                    self.onStatus?("UDP 视频接收端已就绪")
                    self.onReady?(port, generation)
                case .failed(let error):
                    self.failAndStop("UDP 视频接收失败：\(error.localizedDescription)")
                case .waiting(let error):
                    self.onStatus?("UDP 视频接收等待网络：\(error.localizedDescription)")
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                guard let self, let listener, self.listener === listener else {
                    connection.cancel()
                    return
                }
                self.accept(connection)
            }
            listener.start(queue: queue)
            startStatisticsTimer()
        } catch {
            failAndStop("无法创建 UDP 视频接收端：\(error.localizedDescription)")
        }
    }

    private func stopOnQueue() {
        repairTimingPolicy = AdaptiveVideoRepairPolicy()
        usbPending = []; usbPendingBytes = 0; loggedUSB = false
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        for candidate in candidates.values { candidate.cancel() }
        candidates.removeAll()
        startupBuffer.reset()
        statisticsTimer?.cancel()
        statisticsTimer = nil
        resetDeliveryBuffer()
        expectedStreamID = nil
        receiverGeneration = nil
        videoKey = nil
        lastCompletedFrameID = nil
        awaitingRecoveryKeyFrame = false
        packetsReceived = 0
        framesCompleted = 0
        framesDropped = 0
        networkFramesMissing = 0
        lastKeyFrameRequestUptime = 0
        lastCompletedFrameUptime = 0
        lastDecodeErrorReportUptime = 0
        didLogFirstDatagram = false
        didReportInitialKeyFrameWait = false
        didLogFirstFrame = false
        receiveDiagnostics = PadVideoReceiveDiagnostics()
    }

    private func accept(_ candidate: NWConnection) {
        guard connection == nil, candidates.count < 4 else {
            eventLog.record("已拒绝未经授权的新 UDP 来源，当前视频连接保持不变")
            candidate.cancel()
            return
        }
        let candidateID = UUID()
        candidates[candidateID] = candidate
        candidate.stateUpdateHandler = { [weak self, weak candidate] state in
            guard let self, let candidate, self.candidates[candidateID] === candidate else { return }
            switch state {
            case .ready:
                self.authenticateCandidate(candidate, id: candidateID)
            case .failed(let error):
                self.eventLog.record("UDP 候选来源连接失败：\(error.localizedDescription)")
                self.rejectCandidate(candidateID)
            default: break
            }
        }
        candidate.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { [weak self, weak candidate] in
            guard let self, let candidate, self.candidates[candidateID] === candidate else { return }
            self.eventLog.record("UDP 候选来源认证超时，已拒绝连接")
            self.rejectCandidate(candidateID)
        }
    }

    private func rejectCandidate(_ id: UUID) {
        _ = startupBuffer.take(id)
        guard let candidate = candidates.removeValue(forKey: id) else { return }
        candidate.stateUpdateHandler = nil
        candidate.cancel()
    }

    private func authenticateCandidate(_ candidate: NWConnection, id: UUID) {
        candidate.receiveMessage { [weak self, weak candidate] data, _, _, error in
            guard let self, let candidate,
                  self.candidates[id] === candidate || self.connection === candidate else { return }
            if let error {
                if self.connection === candidate {
                    self.failAndStop("视频数据接收错误：\(error.localizedDescription)")
                    return
                }
                self.eventLog.record("UDP 候选来源接收失败：\(error.localizedDescription)")
                self.rejectCandidate(id)
                return
            }
            if let data { self.processCandidatePacket(data, candidate: candidate, id: id) }
            if self.connection === candidate {
                self.startReceiving(on: candidate)
            } else if self.candidates[id] === candidate {
                self.authenticateCandidate(candidate, id: id)
            }
        }
    }

    private func processCandidatePacket(_ data: Data, candidate: NWConnection, id: UUID) {
        if connection === candidate {
            handle(data)
            return
        }
        guard candidates[id] === candidate else { return }
        guard let key = videoKey, let expectedID = expectedStreamID else {
            do { try startupBuffer.append(data, candidate: id) }
            catch {
                eventLog.record("UDP 启动数据暂存失败：\(error.localizedDescription)")
                rejectCandidate(id)
            }
            return
        }
        do {
            let plaintext = try VideoDatagramCrypto.open(data, key: key)
            let fragment = try VideoDatagramCodec.decode(plaintext)
            guard fragment.streamID == expectedID else { throw VideoDatagramCryptoError.authenticationFailed }
        } catch {
            self.eventLog.record("已拒绝 UDP 候选来源：\(error.localizedDescription)")
            self.rejectCandidate(id)
            return
        }
        guard self.connection == nil else {
            self.rejectCandidate(id)
            return
        }
        self.candidates.removeValue(forKey: id)
        for otherID in Array(self.candidates.keys) { self.rejectCandidate(otherID) }
        self.connection = candidate
        candidate.stateUpdateHandler = { [weak self, weak candidate] state in
            guard let self, let candidate, self.connection === candidate else { return }
            if case .failed(let error) = state {
                self.failAndStop("视频发送端断开：\(error.localizedDescription)")
            }
        }
        self.eventLog.record("已认证 Mac 的 UDP 视频来源：\(candidate.endpoint)")
        if let path = candidate.currentPath {
            self.eventLog.record("视频接收路径：\(PeerNetworkTransport.routeDescription(path))")
        }
        self.handle(data)
    }

    private func startReceiving(on activeConnection: NWConnection) {
        guard connection === activeConnection, receivingConnection !== activeConnection else { return }
        receivingConnection = activeConnection
        // 预先挂起有界的一批读取，减少无线突发到达时逐包往返网络栈的空隙。
        activeConnection.batch {
            for _ in 0..<16 { receiveNext(on: activeConnection) }
        }
    }

    private func receiveNext(on activeConnection: NWConnection) {
        activeConnection.receiveMessage { [weak self, weak activeConnection] data, context, _, error in
            let callbackAt = DispatchTime.now().uptimeNanoseconds
            let rawCallbackAt = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
            guard let self, let activeConnection, self.connection === activeConnection else { return }
            if let error {
                self.failAndStop("视频数据接收错误：\(error.localizedDescription)")
                return
            }
            self.receiveNext(on: activeConnection)
            var systemReceivedAt: UInt64?
            if let metadata = context?.protocolMetadata(definition: NWProtocolIP.definition) as? NWProtocolIP.Metadata {
                self.pipelineMetrics.systemReceive(at: metadata.receiveTime,
                    callbackAt: rawCallbackAt)
                if metadata.receiveTime > 0, rawCallbackAt >= metadata.receiveTime {
                    let delay = rawCallbackAt - metadata.receiveTime
                    if delay <= 10_000_000_000, callbackAt >= delay { systemReceivedAt = callbackAt - delay }
                }
            }
            if let data, !data.isEmpty {
                self.handle(data, callbackAt: callbackAt, systemReceivedAt: systemReceivedAt)
            }
        }
    }

    private func handle(_ datagram: Data, callbackAt: UInt64? = nil, systemReceivedAt: UInt64? = nil) {
        let began = DispatchTime.now().uptimeNanoseconds
        defer { pipelineMetrics.processing.record(from: began, to: DispatchTime.now().uptimeNanoseconds) }
        do {
            guard let videoKey else { return }
            let plaintext = try VideoDatagramCrypto.open(datagram, key: videoKey)
            let fragment = try VideoDatagramCodec.decode(plaintext)
            guard expectedStreamID == nil || expectedStreamID == fragment.streamID else { return }
            receiveTiming.packet(fragment.frameID, callbackAt: callbackAt ?? began, systemReceiveAt: systemReceivedAt)
            pipelineMetrics.packet(fragment, bytes: datagram.count, now: began)
            if let detail = receiveDiagnostics.record(fragment, gap: reassembler.lastGap) {
                eventLog.record(detail)
            }
            packetsReceived &+= 1
#if DEBUG
            if repairProbe.shouldDiscard(fragment) {
                eventLog.record("缺片恢复实机验证：仅丢弃一个实际接收的视频分片，帧 \(fragment.frameID)，分片 \(fragment.fragmentIndex + 1)/\(fragment.fragmentCount)")
                return
            }
#endif
            if !didLogFirstDatagram {
                didLogFirstDatagram = true
                eventLog.record(
                    "收到首个视频数据包：流 \(fragment.streamID.uuidString)，帧 \(fragment.frameID)，分片 \(fragment.fragmentIndex + 1)/\(fragment.fragmentCount)"
                )
            }
            // 首个关键帧可能比后续普通帧更晚收齐；普通帧不能推进组帧器的序号，
            // 否则仍在路上的关键帧分片会被误判过期，造成额外黑屏等待。
            if (lastCompletedFrameID == nil || awaitingRecoveryKeyFrame), !fragment.isKeyFrame {
                if !didReportInitialKeyFrameWait {
                    didReportInitialKeyFrameWait = true
                    eventLog.record("参考帧尚未就绪，保留关键帧组装并等待补发")
                }
                requestKeyFrameIfNeeded()
                return
            }
            let completed = reassembler.append(fragment, now: began)
            if reassembler.lastAssembledFrameID == fragment.frameID {
                receiveTiming.assembled(fragment.frameID, now: DispatchTime.now().uptimeNanoseconds)
            }
            deliver(completed)
            scheduleReorderWakeup()
        } catch {
            framesDropped &+= 1
            reportDecodeErrorIfNeeded(error)
            requestKeyFrameIfNeeded()
        }
    }

    private func resetDeliveryBuffer() {
        reorderGeneration = UUID()
        reorderWakeup?.cancel()
        reorderWakeup = nil
        reorderDeadline = nil
        reassembler = VideoFrameDeliveryBuffer(maximumPendingFrames: supportsVideoRepair ? 12 : 6,
            repairEnabled: supportsVideoRepair, earlyRepairEnabled: PadVideoReceiveConfiguration.adaptiveRepair)
        receiveTiming = PadFrameReceiveTimingTracker()
#if DEBUG
        repairProbe = PadVideoRepairProbe()
#endif
        pendingRepair = nil
        repairWaitNanoseconds = 90_000_000
        applyRepairWaitBudget()
        receiveDiagnostics = PadVideoReceiveDiagnostics()
        pipelineMetrics = PadReceivePipelineMetrics()
    }

    func deliver(_ frames: [CompletedVideoFrame]) {
        for frame in frames { deliverFrame(frame) }
    }

    func abandonMissingFrameAfterRepairTimeout(_ frameID: UInt32) {
        // 没有后续完整帧可作为缺口信号时，也要分别统计真实缺失与恢复期舍弃。
        networkFramesMissing &+= 1
        framesDropped &+= 1
        lastCompletedFrameID = frameID
        awaitingRecoveryKeyFrame = true
    }

    private func deliverFrame(_ frame: CompletedVideoFrame) {
        guard !awaitingRecoveryKeyFrame || frame.isKeyFrame else { return }
        if let previous = lastCompletedFrameID {
            guard Self.isNewerFrameID(frame.frameID, than: previous) else { return }
            let distance = frame.frameID &- previous
            if distance > 1 {
                if !awaitingRecoveryKeyFrame { networkFramesMissing &+= UInt64(distance - 1) }
                framesDropped &+= UInt64(distance - 1)
                eventLog.record("检测到视频丢帧：从 \(previous) 跳到 \(frame.frameID)")
                if !frame.isKeyFrame {
                    repairTimingPolicy.recordFailure()
                    if let gap = reassembler.lastGap {
                        eventLog.record(receiveDiagnostics.describe(gap))
                    }
                    awaitingRecoveryKeyFrame = true
                    framesDropped &+= 1
                    lastCompletedFrameID = frame.frameID
                    eventLog.record("视频参考链已中断，停止提交普通帧，等待完整关键帧恢复")
                    requestKeyFrameIfNeeded()
                    return
                }
            }
        }
        if awaitingRecoveryKeyFrame {
            eventLog.record("完整关键帧已收到，视频参考链恢复：帧 \(frame.frameID)")
        }
        if let repair = pendingRepair {
            if frame.frameID == repair.frameID {
                let elapsed = (DispatchTime.now().uptimeNanoseconds - repair.requestedAt) / 1_000_000
                repairTimingPolicy.recordRepair(milliseconds: Double(DispatchTime.now().uptimeNanoseconds - repair.requestedAt) / 1_000_000)
                eventLog.record("视频缺片已补齐：帧 \(frame.frameID)，耗时 \(elapsed) 毫秒，继续原有画面")
                pendingRepair = nil
            } else if frame.isKeyFrame {
                pendingRepair = nil
            }
        }
        awaitingRecoveryKeyFrame = false
        lastCompletedFrameID = frame.frameID
        lastCompletedFrameUptime = DispatchTime.now().uptimeNanoseconds
        framesCompleted &+= 1
        let timing = receiveTiming.delivered(frame.frameID, now: lastCompletedFrameUptime)
        pipelineMetrics.receiveTiming(timing)
        if let timing, let assembled = timing.assembledAt,
           assembled >= timing.firstCallback, lastCompletedFrameUptime >= assembled {
            let assembly = assembled - timing.firstCallback
            let ordering = lastCompletedFrameUptime - assembled
            if assembly >= 50_000_000 || ordering >= 20_000_000 || (timing.maximumCallbackDelay ?? 0) >= 20_000_000 {
                let callback = timing.maximumCallbackDelay.map { "\($0 / 1_000_000) 毫秒" } ?? "未取得系统时间戳"
                eventLog.recordPeriodic("视频接收耗时分解：帧 \(frame.frameID)，首片到组装 \(assembly / 1_000_000) 毫秒，组装后等待 \(ordering / 1_000_000) 毫秒，系统到回调最大 \(callback)",
                                        key: "视频接收耗时分解", intervalNanoseconds: 2_000_000_000)
            }
        }
        pipelineMetrics.frame(frame.frameID, now: lastCompletedFrameUptime)
        if !didLogFirstFrame {
            didLogFirstFrame = true
            eventLog.record(
                "首个完整视频帧已组装：帧 \(frame.frameID)，长度 \(frame.accessUnit.count) 字节，关键帧 \(frame.isKeyFrame)"
            )
        }
        onFrame?(frame, timing)
        applyRepairWaitBudget()
    }

    private func startStatisticsTimer() {
        statisticsTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.publishStatistics()
        }
        statisticsTimer = timer
        timer.resume()
    }

    private func publishStatistics() {
        let now = DispatchTime.now().uptimeNanoseconds
        let cutoff = now > 500_000_000 ? now - 500_000_000 : 0
        if reassembler.discardIncompleteFrames(olderThanUptimeNanoseconds: cutoff) > 0 {
            requestKeyFrameIfNeeded()
        }
        if expectedStreamID != nil,
           packetsReceived > 0,
           now > lastCompletedFrameUptime,
           now - lastCompletedFrameUptime >= 1_500_000_000 {
            requestKeyFrameIfNeeded()
        }
        guard let receiverGeneration, let expectedStreamID else { return }
        if let report = pipelineMetrics.report(streamID: expectedStreamID, now: now) {
            eventLog.record(report)
        }
        onStatistics?(PadVideoReceiveSnapshot(
            generation: receiverGeneration, streamID: expectedStreamID, uptimeNanoseconds: now,
            packets: packetsReceived, assembled: framesCompleted, dropped: framesDropped,
            networkMissing: networkFramesMissing))
        receiveDiagnostics.endInterval()
    }

    private static func isNewerFrameID(_ candidate: UInt32, than previous: UInt32) -> Bool {
        Int32(bitPattern: candidate &- previous) > 0
    }

    func requestKeyFrameIfNeeded() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastKeyFrameRequestUptime >= 500_000_000 else { return }
        lastKeyFrameRequestUptime = now
        onNeedsKeyFrame?()
    }

    private func reportDecodeErrorIfNeeded(_ error: Error) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastDecodeErrorReportUptime >= 2_000_000_000 else { return }
        lastDecodeErrorReportUptime = now
        eventLog.record("视频数据校验失败：\(error.localizedDescription)")
        onStatus?("视频数据校验失败：\(error.localizedDescription)")
    }

    private func failAndStop(_ status: String) {
        eventLog.record(status)
        onStatus?(status)
        stopOnQueue()
        onRecoverableFailure?(status)
    }
}
