import Foundation
import Network
import YingchuiProtocol

final class PadAudioReceiver: @unchecked Sendable {
    var onReady: (@Sendable (UInt16, UUID) -> Void)?
    var onFailure: (@Sendable (String, UUID) -> Void)?
    var onPacket: (@Sendable (AudioPacket) -> Void)?
    private let queue = DispatchQueue(label: "com.yingchui.pad.audio-network", qos: .userInteractive)
    private let player = PadAudioPlayer()
    var playbackStatistics: PadAudioBufferStatistics { player.statistics }
    var diagnosticSummary: String { log.recentSummary(limit: 10) + "\n" + player.diagnosticSummary }
    private let log = DiagnosticEventLog(subsystem: "com.yingchui.interconnect.pad", category: "声音")
    private var listener: NWListener?
    private var active: NWConnection?
    private var candidates: [UUID: NWConnection] = [:]
    private var key: Data?
    private var streamID: UUID?
    private var lastSequence: UInt32?
    private var generation = UUID()

    func receiveUSB(_ data: Data, generation: UUID) {
        queue.async { [weak self] in
            guard let self, self.generation == generation, let key = self.key, let streamID = self.streamID else { return }
            do {
                let packet = try AudioPacketCodec.decode(VideoDatagramCrypto.open(data, key: key))
                guard packet.streamID == streamID else { return }
                if self.lastSequence == nil || Int32(bitPattern: packet.sequence &- self.lastSequence!) > 0 {
                    self.lastSequence = packet.sequence
                    if let onPacket = self.onPacket { onPacket(packet) } else { self.player.enqueue(packet) }
                }
            } catch {
                // 控制配置可先于旧流积压的媒体到达，旧密文不能触发新流反复重建。
                self.log.recordPeriodic("已丢弃无法通过当前声音密钥或格式校验的 USB 数据：\(error.localizedDescription)",
                    key: "USB声音旧流", intervalNanoseconds: 2_000_000_000)
            }
        }
    }

    deinit { stopOnQueue() }

    func start(generation: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopOnQueue()
            self.generation = generation
            self.player.onFailure = { [weak self] error in
                self?.queue.async { [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.fail(error)
                }
            }
            do {
                let parameters = PeerNetworkTransport.audio()
                parameters.serviceClass = .interactiveVoice
                let listener = try NWListener(using: parameters)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener, self.listener === listener else { return }
                    if case .ready = state {
                        guard let port = listener.port else { self.fail("声音端口不可用"); return }
                        self.player.prepare { [weak self, weak listener] in
                            self?.queue.async { [weak self, weak listener] in
                                guard let self, let listener, self.listener === listener,
                                      self.generation == generation else { return }
                                self.onReady?(port.rawValue, generation)
                            }
                        }
                    }
                    if case .failed(let error) = state { self.fail("声音接收失败：\(error.localizedDescription)") }
                }
                listener.newConnectionHandler = { [weak self, weak listener] connection in
                    guard let self, let listener, self.listener === listener else {
                        connection.cancel()
                        return
                    }
                    self.accept(connection)
                }
                listener.start(queue: self.queue)
            } catch { self.fail("声音接收启动失败：\(error.localizedDescription)") }
        }
    }

    func expect(streamID: UUID, key: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            self.active?.cancel(); self.active = nil
            self.streamID = streamID; self.key = key; self.lastSequence = nil
            self.player.resetStream()
        }
    }

    func stop() { queue.async { [weak self] in self?.stopOnQueue() } }

    private func stopOnQueue() {
        generation = UUID()
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        active?.cancel(); active = nil
        candidates.values.forEach { $0.cancel() }; candidates.removeAll()
        key = nil; streamID = nil; lastSequence = nil
        player.stop()
    }

    private func accept(_ connection: NWConnection) {
        guard active == nil, candidates.count < 4 else { connection.cancel(); return }
        let id = UUID()
        candidates[id] = connection
        connection.start(queue: queue)
        receive(connection, id: id)
        queue.asyncAfter(deadline: .now() + 3) { [weak self, weak connection] in
            guard let self, let connection, self.candidates.removeValue(forKey: id) != nil else { return }
            connection.cancel()
        }
    }

    private func receive(_ connection: NWConnection, id: UUID) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection,
                  self.active === connection || self.candidates[id] === connection else { return }
            if let error { self.fail("声音接收失败：\(error.localizedDescription)"); return }
            if let data, let key = self.key, let streamID = self.streamID {
                do {
                    let packet = try AudioPacketCodec.decode(VideoDatagramCrypto.open(data, key: key))
                    guard packet.streamID == streamID else { throw AudioPacketError.invalidPacket }
                    if self.active == nil {
                        self.active = connection
                        self.candidates.removeValue(forKey: id)
                        self.candidates.values.forEach { $0.cancel() }; self.candidates.removeAll()
                    }
                    guard self.active === connection else { connection.cancel(); return }
                    if self.lastSequence == nil || Int32(bitPattern: packet.sequence &- self.lastSequence!) > 0 {
                        self.lastSequence = packet.sequence
                        if let onPacket = self.onPacket { onPacket(packet) }
                        else { self.player.enqueue(packet) }
                    }
                } catch {
                    self.log.record("声音数据认证或格式校验失败：\(error.localizedDescription)")
                    if self.active === connection { self.fail("声音数据校验失败"); return }
                    self.candidates.removeValue(forKey: id); connection.cancel(); return
                }
            }
            self.receive(connection, id: id)
        }
    }

    private func fail(_ error: String) {
        let generation = self.generation
        stopOnQueue()
        log.record(error)
        onFailure?(error, generation)
    }
}
