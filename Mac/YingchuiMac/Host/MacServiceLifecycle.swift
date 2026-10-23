import AppKit
import CoreGraphics
import Foundation
import Network
import Security
import YingchuiProtocol

extension MacHostModel {
    @MainActor
    func restart() {
        statusText = "正在重新启动连接服务"
        networkQueue.async { [weak self] in
            guard let self else { return }
            self.wantsServiceRunning = true
            self.stopOnNetworkQueue(publish: false)
            self.rotatePairingCode()
            self.startOnNetworkQueue()
        }
    }

    @MainActor
    func stop() {
        networkQueue.async { [weak self] in
            guard let self else { return }
            self.wantsServiceRunning = false
            self.stopOnNetworkQueue(publish: true)
        }
    }

    func startOnNetworkQueue() {
        guard wantsServiceRunning, listener == nil else { return }
        listenerRetryWorkItem?.cancel()
        listenerRetryWorkItem = nil
        listenerRetryID = nil
        do {
            guard let tlsIdentity,
                  let protocolIdentity = sec_identity_create(tlsIdentity) else {
                publishFailure(tlsIdentityErrorText ?? "TLS 本机身份初始化失败")
                return
            }
            let tlsOptions = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, protocolIdentity)
            sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv13)
            sec_protocol_options_set_tls_resumption_enabled(tlsOptions.securityProtocolOptions, false)
            let parameters = PeerNetworkTransport.control(tls: tlsOptions)
            let newListener = try NWListener(using: parameters)
            newListener.service = NWListener.Service(
                name: Host.current().localizedName ?? "Mac mini",
                type: YingchuiService.bonjourType,
                txtRecord: NWTXTRecord(HostAdvertisement(hostID: hostID).txtRecord)
            )
            newListener.stateUpdateHandler = { [weak self, weak newListener] state in
                guard let self, let newListener, self.listener === newListener else { return }
                self.handleListenerState(state, listener: newListener)
            }
            newListener.newConnectionHandler = { [weak self, weak newListener] connection in
                guard let self, let newListener, self.listener === newListener else {
                    connection.cancel()
                    return
                }
                self.accept(connection)
            }
            listener = newListener
            newListener.start(queue: networkQueue)
            let timer = DispatchSource.makeTimerSource(queue: networkQueue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self, self.pairingPolicy.isExpired(at: ProcessInfo.processInfo.systemUptime) else { return }
                self.rotatePairingCode()
                self.eventLog.record("配对码已到期，已生成新的配对码")
            }
            pairingTimer?.cancel()
            pairingTimer = timer
            timer.resume()
        } catch {
            publishFailure("服务启动失败：\(error.localizedDescription)")
        }
    }

    func stopOnNetworkQueue(publish: Bool) {
        usbHost.stop()
        pairingTimer?.cancel()
        pairingTimer = nil
        listenerRetryWorkItem?.cancel()
        listenerRetryWorkItem = nil
        listenerRetryID = nil
        listenerRetryAttempt = 0
        let activeListener = listener
        listener = nil
        activeListener?.stateUpdateHandler = nil
        activeListener?.newConnectionHandler = nil
        activeListener?.cancel()
        sessions.values.forEach {
            detachAccountLink($0)
            releaseInputState(for: $0)
            $0.cancel()
        }
        sessions.removeAll()
        controlSessionID = nil
        publishTrustedDevices()
        stopStreaming()
        if publish {
            publishStopped()
        }
    }

    func handleListenerState(_ state: NWListener.State, listener: NWListener) {
        switch state {
        case .ready:
            listenerRetryAttempt = 0
            if let port = listener.port { usbHost.start(hostID: hostID, listenerPort: port) }
            eventLog.record("附近设备服务已就绪，支持局域网与无线直连")
            let port = listener.port.map { String($0.rawValue) } ?? "自动"
            Task { @MainActor [weak self] in
                self?.isRunning = true
                self?.statusText = self?.credentialStoreErrorText ?? "等待客户端连接"
                self?.portText = port
            }
        case .failed(let error):
            usbHost.stop()
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
            self.listener = nil
            publishFailure("监听失败：\(error.localizedDescription)")
            scheduleListenerRestart()
        case .cancelled:
            publishStopped()
        case .waiting(let error):
            publishStatus("等待网络：\(error.localizedDescription)")
        default:
            break
        }
    }

    func handleNetworkPathUpdate(_ state: LocalNetworkState) {
        guard lastNetworkState != state else { return }
        lastNetworkState = state
        // 默认路由断开不代表点对点不可达，保留监听与已建立的会话。
        eventLog.record(state.isAvailable ? "普通网络路径可用，附近设备服务保持运行" : "普通网络路径不可用，附近设备服务继续等待无线直连")
        if wantsServiceRunning, listener == nil, listenerRetryWorkItem == nil {
            startOnNetworkQueue()
        }
    }

    func scheduleListenerRestart() {
        guard wantsServiceRunning, listenerRetryWorkItem == nil else { return }
        let delay = min(30.0, pow(2.0, Double(min(listenerRetryAttempt, 5))))
        listenerRetryAttempt += 1
        let id = UUID()
        listenerRetryID = id
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.listenerRetryID == id else { return }
            self.listenerRetryWorkItem = nil
            self.listenerRetryID = nil
            self.startOnNetworkQueue()
        }
        listenerRetryWorkItem = workItem
        networkQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func accept(_ connection: NWConnection) {
        guard !automaticUpdateBarrier.value else {
            publishStatus("应用正在安装更新，请稍后重新连接")
            connection.cancel()
            return
        }
        guard sessions.count < 16, sessions.values.filter({ !$0.isAuthorized }).count < 8 else {
            publishStatus("客户端连接数量超限，已拒绝新连接")
            connection.cancel()
            return
        }
        let session = HostPeerSession(
            connection: connection,
            onMessage: { [weak self] session, message in
                self?.handle(message, from: session)
            },
            onClosed: { [weak self] session in
                self?.remove(session)
            },
            onStatus: { [weak self] status in
                self?.publishStatus(status)
            }
        )
        sessions[session.id] = session
        publishSessionCount()
        session.start(on: networkQueue)
    }
}
