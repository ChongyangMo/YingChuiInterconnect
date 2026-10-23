import Foundation
import Network
import YingchuiProtocol

extension PadConnectionModel {
    func configureUSBService() {
        let service = PadUSBService(queue: networkQueue, log: eventLog)
        usbService = service
        service.onHost = { [weak self] id, introduction, endpoint in
            guard let self else { return }
            self.usbDiscoveredHosts[id] = DiscoveredHost(endpoint: endpoint, name: introduction.name + " (USB)", hostID: introduction.hostID)
            self.publishDiscoveredRoutes()
            if self.connectedHostKey == introduction.hostID, let active = self.connection,
               active.endpoint != endpoint {
                self.desiredEndpoint = endpoint
                self.handleConnectionClosed(active, reason: "USB 已就绪，正在切换有线连接")
            }
        }
        service.onRemoved = { [weak self] id in
            guard let self else { return }
            let removed = self.usbDiscoveredHosts.removeValue(forKey: id)
            if self.desiredEndpoint == removed?.endpoint,
               let fallback = self.networkDiscoveredHosts.first(where: { $0.hostID == removed?.hostID })?.endpoint {
                self.desiredEndpoint = fallback
            }
            self.publishDiscoveredRoutes()
            if self.connection == nil { self.scheduleReconnectIfNeeded() }
        }
        service.onMedia = { [weak self] id, packet in
            guard let self, let host = self.usbDiscoveredHosts[id], self.connection?.endpoint == host.endpoint,
                  let generation = self.videoReceiverGeneration.value else { return }
            switch packet.kind {
            case .video: self.videoReceiver.receiveUSB(packet.payload, generation: generation)
            case .audio: self.audioReceiver.receiveUSB(packet.payload, generation: generation)
            default: break
            }
        }
    }

    func publishDiscoveredRoutes() {
        var hosts = Dictionary(networkDiscoveredHosts.map { ($0.hostID, $0) }, uniquingKeysWith: { _, last in last })
        for host in usbDiscoveredHosts.values { hosts[host.hostID] = host }
        let merged = hosts.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        refreshDesiredEndpoint(from: merged)
        Task { @MainActor [weak self] in self?.discoveredHosts = merged }
    }
}
