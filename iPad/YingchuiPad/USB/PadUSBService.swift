import Foundation
import Network
import YingchuiProtocol

final class PadUSBService: @unchecked Sendable {
    private final class Session: @unchecked Sendable {
        let channel: USBPacketChannel
        var proxy: NWListener?
        var relay: USBControlRelay?
        var introduced = false
        init(_ channel: USBPacketChannel) { self.channel = channel }
        func close() { proxy?.cancel(); relay?.close(); channel.close() }
    }
    var onHost: (@Sendable (UUID, USBHostIntroduction, NWEndpoint) -> Void)?
    var onRemoved: (@Sendable (UUID) -> Void)?
    var onMedia: (@Sendable (UUID, USBPacket) -> Void)?
    private let queue: DispatchQueue
    private let log: DiagnosticEventLog
    private var listener: NWListener?
    private var sessions: [UUID: Session] = [:]
    init(queue: DispatchQueue, log: DiagnosticEventLog) { self.queue = queue; self.log = log }

    func start() {
        guard listener == nil else { return }
        do {
            let settings = try USBTransportConfiguration.load()
            guard settings.enabled, let port = NWEndpoint.Port(rawValue: settings.devicePort) else { return }
            let parameters = NWParameters.tcp
            (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                guard let self, let listener, self.listener === listener, self.sessions.count < 4 else { connection.cancel(); return }
                self.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, self.listener === listener else { return }
                if case .ready = state { self.log.record("USB 接入服务已就绪，等待 Mac 数据线连接") }
                if case .failed(let error) = state {
                    self.log.record("USB 接入服务失败：\(error.localizedDescription)"); self.stop()
                }
            }
            listener.start(queue: queue)
        } catch { log.record("USB 接入启动失败：\(error.localizedDescription)") }
    }
    func stop() {
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        let previous = sessions; sessions.removeAll()
        for (id, session) in previous { session.close(); onRemoved?(id) }
    }
    private func accept(_ raw: NWConnection) {
        let id = UUID(), channel = USBPacketChannel(connection: raw, queue: queue)
        let session = Session(channel); sessions[id] = session
        channel.onPacket = { [weak self, weak session] packet in
            guard let self, let session, self.sessions[id] === session else { return }
            do {
                switch packet.kind {
                case .introduction:
                    guard !session.introduced else { throw USBPacketError.invalidIntroduction }
                    let introduction = try USBHostIntroduction.decode(packet.payload)
                    session.introduced = true
                    try self.prepareProxy(id, session: session, introduction: introduction)
                case .control:
                    guard let relay = session.relay else { throw USBPacketError.invalidFrame }
                    relay.write(packet.payload)
                case .video, .audio:
                    guard session.introduced, session.relay != nil else { throw USBPacketError.invalidFrame }
                    self.onMedia?(id, packet)
                }
            } catch { self.log.record("USB 接入数据无效：\(error.localizedDescription)"); self.remove(id) }
        }
        channel.onClosed = { [weak self] reason in self?.log.record(reason); self?.remove(id) }
        channel.start()
        queue.asyncAfter(deadline: .now()+5) { [weak self, weak session] in
            guard let self, let session, self.sessions[id] === session, !session.introduced else { return }
            self.remove(id)
        }
    }
    private func prepareProxy(_ id: UUID, session: Session, introduction: USBHostIntroduction) throws {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let proxy = try NWListener(using: parameters)
        session.proxy = proxy
        proxy.stateUpdateHandler = { [weak self, weak proxy, weak session] state in
            guard let self, let proxy, let session, self.sessions[id] === session else { return }
            if case .ready = state, let port = proxy.port {
                self.onHost?(id, introduction, .hostPort(host: "127.0.0.1", port: port))
            }
            if case .failed = state { self.remove(id) }
        }
        proxy.newConnectionHandler = { [weak self, weak session] local in
            guard let self, let session, self.sessions[id] === session, session.relay == nil else { local.cancel(); return }
            let relay = USBControlRelay(local: local, channel: session.channel, queue: self.queue)
            session.relay = relay; relay.start()
        }
        proxy.start(queue: queue)
    }
    private func remove(_ id: UUID) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        session.close(); onRemoved?(id)
    }
}
