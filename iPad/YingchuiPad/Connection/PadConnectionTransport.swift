import CryptoKit
import Foundation
import Network
import Security
import YingchuiProtocol

extension PadConnectionModel {
    func connectOnNetworkQueue(to endpoint: NWEndpoint, includePeerToPeer: Bool = false) {
        guard !isInBackgroundState.value, connection == nil else { return }
        guard credentialStoreErrorText == nil else {
            desiredEndpoint = nil
            publishStatus(credentialStoreErrorText ?? "配对凭据无效，请重置信任")
            return
        }
        let epoch = UUID()
        connectionEpoch.set(epoch)
        pendingConnectionFailureReason = nil
        peerMinimumProtocolVersion = nil
        wireVersion = YingchuiService.protocolVersion
        hevcDisabled.set(false)
        activeVideoCodec.set(.h264)
        let hostKey = connectedHostKey ?? ""
        let expectedFingerprint = trustStore.credential(for: hostKey)?.certificateFingerprint
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_tls_resumption_enabled(tlsOptions.securityProtocolOptions, false)
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { [weak self] _, trust, complete in
                guard let self, self.connectionEpoch.value == epoch else { complete(false); return }
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                guard let certificateChain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                      let certificate = certificateChain.first else {
                    complete(false)
                    return
                }
                let certificateData = SecCertificateCopyData(certificate) as Data
                let fingerprint = Data(SHA256.hash(data: certificateData)).base64EncodedString()
                guard expectedFingerprint == nil || expectedFingerprint == fingerprint else {
                    self.pendingConnectionFailureReason = "TLS 证书与已配对的 Mac 不一致，已拒绝连接"
                    self.desiredEndpoint = nil
                    complete(false)
                    return
                }
                self.pendingCertificateFingerprint = fingerprint
                do {
                    self.pendingLegacyCredential = expectedFingerprint == nil
                        ? try self.trustStore.legacyCredential(matching: fingerprint) : nil
                } catch {
                    self.pendingConnectionFailureReason = "旧配对记录校验失败：\(error.localizedDescription)"
                    self.desiredEndpoint = nil
                    complete(false)
                    return
                }
                complete(true)
            },
            networkQueue
        )
        // 显式的点对点地址保留原作用域；Bonjour 服务先走普通局域网。
        let explicitPeer: Bool
        if case .hostPort(let host, _) = endpoint {
            explicitPeer = host.interface?.name.hasPrefix("awdl") == true
        } else { explicitPeer = false }
        connectionAllowsPeerToPeer = includePeerToPeer || explicitPeer
        let parameters = PeerNetworkTransport.control(tls: tlsOptions, includePeerToPeer: connectionAllowsPeerToPeer)
        let newConnection = NWConnection(to: PeerNetworkTransport.reconnectEndpoint(endpoint), using: parameters)
        connection = newConnection

        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let newConnection, self.connection === newConnection, self.connectionEpoch.value == epoch else { return }
            switch state {
            case .ready:
                self.handleConnectionReady(newConnection)
            case .failed(let error):
                if self.retryWithPeerToPeer(on: newConnection, endpoint: endpoint, epoch: epoch) { return }
                let reason = self.pendingConnectionFailureReason
                    ?? "连接失败：\(error.localizedDescription)"
                self.handleConnectionClosed(newConnection, reason: reason)
            case .cancelled:
                self.handleConnectionClosed(newConnection, reason: "连接已断开")
            case .waiting(let error):
                self.publishStatus("等待网络：\(error.localizedDescription)")
            default:
                break
            }
        }
        armConnectionDeadline(.connecting, on: newConnection)
        armLocalNetworkFallback(for: newConnection, endpoint: endpoint)
        newConnection.start(queue: networkQueue)
    }

    func disconnectOnNetworkQueue() {
        connectionRouteFallbackWorkItem?.cancel()
        connectionRouteFallbackWorkItem = nil
        connectionAllowsPeerToPeer = false
        detachAccountLink()
        hostSupportsAccountLink = false
        connectionEpoch.set(UUID())
        cancelConnectionDeadline()
        pendingHelloID = nil
        videoReceiverGeneration.set(nil)
        videoRequestID.set(nil)
        videoConfigurationDeadline?.cancel()
        videoConfigurationDeadline = nil
        requestedDisplayConfiguration = nil
        videoConfigurationPending = false
        let hadPendingTransfer = pendingClipboardRequest != nil || !pendingTextIDs.isEmpty
        pendingClipboardRequest = nil
        pendingTextIDs.removeAll()
        pendingKeyboardLanguageRequest = nil
        requestedKeyboardLanguage = nil
        keyboardLanguageTimeout?.cancel()
        keyboardLanguageTimeout = nil
        if hadPendingTransfer { publishTransferStatus("连接已断开，传送未完成") }
        pendingPairRequestID = nil
        let epoch = connectionEpoch.value
        Task { @MainActor [weak self] in
            guard let self, self.connectionEpoch.value == epoch else { return }
            self.isPairing = false
            self.activeDisplayState = nil
            self.displayModeChanging = false
            self.remoteKeyboardLanguage = .english
            self.supportsDirectTouch = false
            self.supportsTouchHover = false
            self.keyboardLanguageChanging = false
        }
        pingTimer?.cancel()
        pingTimer = nil
        let activeConnection = connection
        connection = nil
        activeConnection?.stateUpdateHandler = nil
        activeConnection?.cancel()
        pendingPings.removeAll()
        peerClockEstimator.reset()
        peerClockEstimateState.set(nil)
        controlAcknowledgements.reset()
        controlPipelineMetrics = PadControlPipelineMetrics()
        didReportControlAcknowledgementTimeout = false
        latestControlRoundTripState.set(nil)
        pendingVisualControlState.set(nil)
        clockOffsetMilliseconds = nil
        decoder = WireMessageDecoder()
        pendingCertificateFingerprint = nil
        pendingLegacyCredential = nil
        pendingConnectionFailureReason = nil
        activeStreamID = nil
        streamReconfigureWorkItem?.cancel()
        streamReconfigureWorkItem = nil
        streamRecoveryWorkItem?.cancel()
        streamRecoveryWorkItem = nil
        activeVideoPort = nil
        audioReceiver.stop()
        activeAudioPort = nil
        videoReceiver.stop()
        pendingCursorInput = nil
        pendingCursorStreamID = nil
        pendingPointerX = 0
        pendingPointerY = 0
        pointerFlushID = nil
        resumeBrowsingAfterDisconnect()
    }

    func handleConnectionReady(_ readyConnection: NWConnection) {
        connectionRouteFallbackWorkItem?.cancel()
        connectionRouteFallbackWorkItem = nil
        pauseBrowsingForConnection()
        if let path = readyConnection.currentPath {
            eventLog.record("控制连接已建立：" + PeerNetworkTransport.routeDescription(path))
        }
        reconnectAttempt = 0
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        let helloID = UUID()
        pendingHelloID = helloID
        armConnectionDeadline(.identifying, on: readyConnection)
        send(
            WireMessage(
                id: helloID,
                kind: .hello,
                deviceName: localDeviceName,
                deviceID: deviceID,
                sessionToken: connectedHostKey.flatMap { trustStore.credential(for: $0)?.token }
                    ?? pendingLegacyCredential?.token,
                supportsAccountLink: true,
                minimumProtocolVersion: WireProtocolCompatibility.minimumSupportedVersion
            ),
            over: readyConnection
        )
        receiveNext(on: readyConnection)
        startPingTimer()

        let epoch = connectionEpoch.value
        Task { @MainActor [weak self] in
            guard let self, self.connectionEpoch.value == epoch else { return }
            self.isConnected = true
            self.statusText = "已连接，正在确认配对状态"
        }
        sendPingOnNetworkQueue()
    }

}
