import Foundation
import Network
import YingchuiProtocol

final class MacUSBHostManager: @unchecked Sendable {
    private struct Session {
        let channel: USBPacketChannel
        let relay: USBControlRelay
        var localPort: UInt16?
    }
    private let queue: DispatchQueue
    private let log: DiagnosticEventLog
    private var timer: DispatchSourceTimer?
    private var sessions: [String: Session] = [:]
    private var connecting: Set<String> = []
    private var configuration: USBTransportConfiguration?
    private var listenerPort: NWEndpoint.Port?
    private var hostID = ""
    private var generation = UUID()
    private var polling = false

    init(queue: DispatchQueue, log: DiagnosticEventLog) { self.queue = queue; self.log = log }
    func start(hostID: String, listenerPort: NWEndpoint.Port) {
        guard timer == nil else { return }
        do {
            let configuration = try USBTransportConfiguration.load()
            guard configuration.enabled else { return }
            self.configuration = configuration; self.hostID = hostID; self.listenerPort = listenerPort
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 2)
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer; timer.resume()
            log.record("USB 设备发现已启动，等待数据线连接")
        } catch { log.record("USB 配置读取失败：\(error.localizedDescription)") }
    }
    func stop() {
        generation = UUID(); timer?.cancel(); timer = nil
        let previous = sessions; sessions.removeAll(); connecting.removeAll(); polling = false
        previous.values.forEach { $0.relay.close(); $0.channel.close() }
    }
    func mediaSink(remoteEndpoint: NWEndpoint?) -> USBMediaPacketSink? {
        guard case .hostPort(let host, let port) = remoteEndpoint,
              Self.isRelayLoopback(host),
              let channel = sessions.values.first(where: { $0.localPort == port.rawValue })?.channel else { return nil }
        return { [weak channel] kind, data, completion in
            guard let channel else { completion(.posix(.ECONNABORTED)); return }
            channel.send(kind, payload: data, completion: completion)
        }
    }
    static func isRelayLoopback(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address): return address.rawValue == Data([127,0,0,1])
        case .ipv6(let address): return address.rawValue == Data([0,0,0,0,0,0,0,0,0,0,255,255,127,0,0,1])
        default: return false
        }
    }
    private func poll() {
        guard !polling, let configuration, let listenerPort else { return }
        polling = true
        let expected = generation
        Task { [weak self] in
            guard let self else { return }
            do {
                let devices = try await MacUSBMuxClient.devices(queue: self.queue)
                self.queue.async { [weak self] in
                    guard let self, self.generation == expected else { return }
                    self.polling = false
                    let present = Set(devices.map(\.serial))
                    for serial in Array(self.sessions.keys) where !present.contains(serial) { self.remove(serial) }
                    for device in devices where self.sessions[device.serial] == nil && !self.connecting.contains(device.serial) {
                        self.connecting.insert(device.serial)
                        self.dial(device, configuration: configuration, listenerPort: listenerPort, generation: expected)
                    }
                }
            } catch {
                self.queue.async { [weak self] in
                    guard let self, self.generation == expected else { return }
                    self.polling = false
                    self.log.recordPeriodic("USB 设备查询失败：\(error.localizedDescription)", key: "USB查询", intervalNanoseconds: 30_000_000_000)
                }
            }
        }
    }
    private func dial(_ device: MacUSBDevice, configuration: USBTransportConfiguration, listenerPort: NWEndpoint.Port, generation expected: UUID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let raw = try await MacUSBMuxClient.connect(device, port: configuration.devicePort, queue: self.queue)
                self.queue.async { [weak self] in
                    guard let self, self.generation == expected else { raw.cancel(); return }
                    self.connecting.remove(device.serial)
                    let channel = USBPacketChannel(connection: raw, queue: self.queue)
                    let parameters = NWParameters.tcp
                    let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options
                    tcp?.noDelay = true
                    let local = NWConnection(host: "127.0.0.1", port: listenerPort, using: parameters)
                    let relay = USBControlRelay(local: local, channel: channel, queue: self.queue)
                    self.sessions[device.serial] = Session(channel: channel, relay: relay)
                    relay.onReady = { [weak self, weak channel] connection in
                        guard let self, let channel, self.sessions[device.serial]?.channel === channel,
                              case .hostPort(_, let port) = connection.currentPath?.localEndpoint else { return }
                        self.sessions[device.serial]?.localPort = port.rawValue
                    }
                    channel.onPacket = { [weak relay, weak channel] packet in
                        guard packet.kind == .control else { channel?.close(); return }
                        relay?.write(packet.payload)
                    }
                    channel.onClosed = { [weak self, weak channel] reason in
                        guard let self, let channel, self.sessions[device.serial]?.channel === channel else { return }
                        self.log.record(reason); self.remove(device.serial)
                    }
                    channel.start(alreadyStarted: true)
                    do {
                        let intro = USBHostIntroduction(hostID: self.hostID, name: Host.current().localizedName ?? "Mac")
                        channel.send(.introduction, payload: try JSONEncoder().encode(intro))
                        relay.start()
                        self.log.record("已建立 USB 原始通道，等待现有 TLS 身份校验与配对")
                    } catch { self.remove(device.serial) }
                }
            } catch {
                self.queue.async { [weak self] in
                    guard let self, self.generation == expected else { return }
                    self.connecting.remove(device.serial)
                    self.log.recordPeriodic("USB 设备尚未就绪，请解锁 iPad 并打开应用：\(error.localizedDescription)", key: "USB连接", intervalNanoseconds: 30_000_000_000)
                }
            }
        }
    }
    private func remove(_ serial: String) {
        guard let session = sessions.removeValue(forKey: serial) else { return }
        session.relay.close(); session.channel.close()
    }
}
