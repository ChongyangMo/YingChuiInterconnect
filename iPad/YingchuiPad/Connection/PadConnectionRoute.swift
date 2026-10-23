import Foundation
import Network
import YingchuiProtocol

extension PadConnectionModel {
    func armLocalNetworkFallback(for active: NWConnection, endpoint: NWEndpoint) {
        connectionRouteFallbackWorkItem?.cancel()
        connectionRouteFallbackWorkItem = nil
        guard !connectionAllowsPeerToPeer, case .service = endpoint else { return }
        eventLog.record("先尝试局域网控制连接，未就绪时再尝试附近直连")
        let epoch = connectionEpoch.value
        let item = DispatchWorkItem { [weak self, weak active] in
            guard let self, let active else { return }
            _ = self.retryWithPeerToPeer(on: active, endpoint: endpoint, epoch: epoch)
        }
        connectionRouteFallbackWorkItem = item
        networkQueue.asyncAfter(deadline: .now() + .seconds(2), execute: item)
    }

    @discardableResult
    func retryWithPeerToPeer(on active: NWConnection, endpoint: NWEndpoint, epoch: UUID) -> Bool {
        guard connection === active, connectionEpoch.value == epoch,
              connectionPhase == .connecting, !connectionAllowsPeerToPeer,
              !isInBackgroundState.value, desiredEndpoint != nil,
              pendingConnectionFailureReason == nil, case .service = endpoint else { return false }
        eventLog.record("局域网连接未就绪，保留身份校验并尝试附近点对点连接")
        disconnectOnNetworkQueue()
        connectOnNetworkQueue(to: endpoint, includePeerToPeer: true)
        return true
    }
}
