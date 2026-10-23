import CryptoKit
import Foundation
import Network
import Security
import UIKit
import YingchuiProtocol

extension PadConnectionModel {
    @MainActor
    func restartBrowsing() {
        discoveredHosts = []
        discoveryStatus = "正在重新查找附近的 Mac"
        networkQueue.async { [weak self] in
            guard let self else { return }
            self.stopBrowsingOnNetworkQueue()
            // 用户主动刷新时仍可查找其他电脑；正常回传不持续搜索。
            self.discoveryPausedForConnection = false
            self.startBrowsingOnNetworkQueue()
        }
    }

    func startBrowsingOnNetworkQueue() {
        if !isInBackgroundState.value { usbService?.start() }
        guard browser == nil, !isInBackgroundState.value, !discoveryPausedForConnection else { return }
        let parameters = PeerNetworkTransport.discovery()
        let newBrowser = NWBrowser(
            for: .bonjourWithTXTRecord(type: YingchuiService.bonjourType, domain: nil),
            using: parameters
        )
        browser = newBrowser

        newBrowser.stateUpdateHandler = { [weak self, weak newBrowser] state in
            guard let self, let newBrowser, self.browser === newBrowser else { return }
            switch state {
            case .ready:
                self.publishDiscoveryStatus("正在查找 Mac")
            case .failed(let error):
                newBrowser.stateUpdateHandler = nil
                newBrowser.browseResultsChangedHandler = nil
                newBrowser.cancel()
                self.browser = nil
                self.publishDiscoveryStatus("扫描失败：\(error.localizedDescription)")
            case .waiting(let error):
                self.publishDiscoveryStatus("附近设备发现暂不可用：\(error.localizedDescription)")
            default:
                break
            }
        }

        newBrowser.browseResultsChangedHandler = { [weak self, weak newBrowser] results, _ in
            guard let self, let newBrowser, self.browser === newBrowser else { return }
            var hostsByID: [String: DiscoveredHost] = [:]
            var incompatibleHostCount = 0
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint,
                      case let .bonjour(txtRecord) = result.metadata,
                      let advertisement = HostAdvertisement(txtRecord: txtRecord.dictionary),
                      advertisement.isCompatible else {
                    incompatibleHostCount += 1
                    continue
                }
                let hostID = advertisement.hostID
                hostsByID[hostID] = DiscoveredHost(
                    endpoint: PeerNetworkTransport.reconnectEndpoint(result.endpoint),
                    name: name,
                    hostID: hostID
                )
            }
            let hosts = hostsByID.values.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }

            self.refreshDesiredEndpoint(from: hosts)
            self.networkDiscoveredHosts = hosts
            self.publishDiscoveredRoutes()
            Task { @MainActor [weak self, weak newBrowser] in
                guard let self, let newBrowser, self.browser === newBrowser else { return }
                if incompatibleHostCount > 0 {
                    self.discoveryStatus = hosts.isEmpty
                        ? "发现不兼容的 Mac，请更新 Mac 客户端"
                        : "部分 Mac 客户端版本不兼容"
                } else {
                    self.discoveryStatus = hosts.isEmpty ? "正在查找 Mac" : "已发现 Mac"
                }
            }
        }

        newBrowser.start(queue: networkQueue)
    }

    func stopBrowsingOnNetworkQueue() {
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
    }

    func pauseBrowsingForConnection() {
        resumeDiscoveryOnDisconnect = resumeDiscoveryOnDisconnect || browser != nil
        discoveryPausedForConnection = true
        guard browser != nil else { return }
        stopBrowsingOnNetworkQueue()
        eventLog.record("已连接电脑，暂停附近设备搜索，减少回传期间的点对点发现活动")
    }

    func resumeBrowsingAfterDisconnect() {
        discoveryPausedForConnection = false
        guard resumeDiscoveryOnDisconnect else { return }
        resumeDiscoveryOnDisconnect = false
        startBrowsingOnNetworkQueue()
    }

    func publishDiscoveryStatus(_ status: String) {
        eventLog.record(status)
        Task { @MainActor [weak self] in self?.discoveryStatus = status }
    }

    func refreshDesiredEndpoint(from hosts: [DiscoveredHost]) {
        guard desiredEndpoint != nil, let id = connectedHostKey,
              let host = hosts.first(where: { $0.hostID == id }) else { return }
        desiredEndpoint = PeerNetworkTransport.reconnectEndpoint(host.endpoint)
        if connection == nil { scheduleReconnectIfNeeded() }
    }

    func handleNetworkPathUpdate(_ state: LocalNetworkState) {
        guard lastNetworkState != state else { return }
        lastNetworkState = state
        // 点对点链路不一定出现在默认路由中；连接、握手与心跳自己决定是否断开。
        eventLog.record(state.isAvailable ? "普通网络路径可用，保留当前连接与发现" : "普通网络路径不可用，继续查找附近设备并允许无线直连")
        guard !isInBackgroundState.value else { return }
        if browser == nil { startBrowsingOnNetworkQueue() }
        if connection == nil { scheduleReconnectIfNeeded() }
    }
}
