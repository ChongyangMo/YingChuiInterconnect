import CryptoKit
import Foundation
import Network
import Security
import UIKit
import YingchuiProtocol

extension PadConnectionModel {
    @MainActor
    func forgetAllHostTrust() {
        networkQueue.async { [weak self] in
            guard let self else { return }
            self.desiredEndpoint = nil
            self.wantsStreaming = false
            self.disconnectOnNetworkQueue()
            do {
                try self.trustStore.removeAll()
                self.credentialStoreErrorText = nil
            } catch {
                self.failTrust("重置全部配对信息失败：\(error.localizedDescription)", storageFailure: true)
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.videoIsPlaying = false
                self.videoRenderer.reset()
                self.requiresAllTrustReset = false
                self.canResetCurrentHostTrust = false
                self.isPaired = false
                self.isConnected = false
                self.isStreaming = false
                self.pairingMessage = "已清除全部 Mac 配对信息，请重新选择 Mac 并配对"
                self.statusText = self.pairingMessage
            }
        }
    }

    @MainActor
    func forgetCurrentHostTrust() {
        guard let connectedHostKey else { return }
        networkQueue.async { [weak self] in
            guard let self else { return }
            self.desiredEndpoint = nil
            self.wantsStreaming = false
            self.disconnectOnNetworkQueue()
            do {
                try self.trustStore.remove(hostID: connectedHostKey)
                self.credentialStoreErrorText = nil
            } catch {
                self.failTrust("清除配对信息失败：\(error.localizedDescription)", storageFailure: true)
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.videoIsPlaying = false
                self.videoRenderer.reset()
                self.pairingMessage = "已清除本机保存的令牌和证书，请重新连接配对"
                self.statusText = "已忘记此 Mac"
                self.isPaired = false
                self.isConnected = false
                self.isStreaming = false
                self.canResetCurrentHostTrust = false
            }
        }
    }

    @MainActor
    func submitPairingCode(_ code: String) {
        let normalized = code.filter(\.isNumber)
        guard normalized.count == 6 else {
            pairingMessage = "请输入六位数字配对码"
            return
        }
        guard !isPairing else { return }
        isPairing = true
        pairingMessage = "正在验证配对码"
        networkQueue.async { [weak self] in
            guard let self else { return }
            guard let connection = self.connection, self.pendingHelloID == nil else {
                Task { @MainActor [weak self] in
                    self?.isPairing = false
                    self?.pairingMessage = "连接已断开，请重新选择 Mac"
                }
                return
            }
            let request = WireMessage(kind: .pairRequest, deviceName: self.localDeviceName,
                                      deviceID: self.deviceID, pairingCode: normalized)
            self.pendingPairRequestID = request.id
            self.armConnectionDeadline(.pairing, on: connection)
            self.send(request, over: connection)
        }
    }

    func handleHello(_ message: WireMessage) {
        guard message.id == pendingHelloID else {
            failTrust("Mac 返回了未请求的身份确认，已拒绝连接")
            return
        }
        pendingHelloID = nil
        cancelConnectionDeadline()
        guard let connectedHostKey, message.hostID == connectedHostKey else {
            failTrust("Mac 身份与局域网广播不一致，已拒绝连接")
            return
        }
        if message.accepted == true {
            guard let credential = trustStore.credential(for: connectedHostKey) ?? pendingLegacyCredential,
                  credential.certificateFingerprint == pendingCertificateFingerprint else {
                failTrust("Mac 未通过已保存的证书与令牌验证，已拒绝连接")
                return
            }
            if trustStore.credential(for: connectedHostKey) == nil {
                do {
                    try trustStore.bindLegacyCredential(credential, to: connectedHostKey)
                    eventLog.record("证书与令牌验证通过，旧配对记录已迁移到稳定主机编号")
                } catch {
                    failTrust("保存旧配对迁移结果失败：\(error.localizedDescription)", storageFailure: true)
                    return
                }
            }
        }
        hostSupportsAccountLink = message.supportsAccountLink == true
        accountLinkAuthorized = message.accepted == true
        attachAccountLink()
        pendingLegacyCredential = nil
        let hasTrust = trustStore.credential(for: connectedHostKey) != nil
        let epoch = connectionEpoch.value
        Task { @MainActor [weak self] in
            guard let self, self.connectionEpoch.value == epoch else { return }
            if let name = message.deviceName { self.connectedHostName = name }
            self.isPairing = false
            self.supportsDirectTouch = message.supportsTouch == true
            self.supportsTouchHover = message.supportsTouchHover == true
            self.isPaired = message.accepted == true
            self.pairingMessage = self.isPaired ? "可信设备已自动配对" : "请输入 Mac 上显示的六位配对码"
            self.statusText = self.isPaired ? "控制通道已就绪" : "等待配对"
            self.canResetCurrentHostTrust = hasTrust
            if self.isPaired { self.rememberConnectedHost() }
            if self.isPaired, self.wantsStreaming {
                self.isStreaming = false
                self.startStreaming()
            }
        }
    }

    func handlePairResult(_ message: WireMessage) {
        if message.detail != "trust_revoked" || message.accepted == true {
            guard pendingPairRequestID == message.id else {
                failTrust("Mac 返回了未请求的配对结果，已拒绝建立信任")
                return
            }
            pendingPairRequestID = nil
            cancelConnectionDeadline()
        }
        guard let connectedHostKey else {
            failTrust("未找到当前配对主机，已拒绝配对结果")
            return
        }
        if message.accepted == true {
            do {
                guard let token = message.sessionToken, let pin = pendingCertificateFingerprint else {
                    throw HostTrustError.incompleteCredential
                }
                try trustStore.save(HostCredential(token: token, certificateFingerprint: pin), for: connectedHostKey)
                credentialStoreErrorText = nil
            } catch {
                failTrust("保存完整配对凭据失败：\(error.localizedDescription)", storageFailure: true)
                return
            }
        } else if message.detail == "trust_revoked" {
            do {
                try trustStore.remove(hostID: connectedHostKey)
            } catch {
                failTrust("移除已撤销的配对凭据失败：\(error.localizedDescription)", storageFailure: true)
                return
            }
            wantsStreaming = false
            activeStreamID = nil
            audioReceiver.stop()
            activeAudioPort = nil
            videoReceiver.stop()
        }
        if message.accepted == true {
            accountLinkAuthorized = true
            attachAccountLink()
        } else { detachAccountLink() }
        let failureText: String
        switch message.detail {
        case "pairing_rate_limited": failureText = "配对尝试过于频繁，请一分钟后重试"
        case "pairing_code_expired": failureText = "配对码已过期，请查看 Mac 上的新配对码"
        case "credential_store_failed": failureText = "Mac 无法保存配对凭据，请检查钥匙串后重试"
        case "trust_revoked": failureText = "Mac 已撤销配对，请重新配对"
        default: failureText = "配对码不正确，请重试"
        }
        let hasTrust = trustStore.credential(for: connectedHostKey) != nil
        let epoch = connectionEpoch.value
        Task { @MainActor [weak self] in
            guard let self, self.connectionEpoch.value == epoch else { return }
            self.isPairing = false
            self.isPaired = message.accepted == true
            self.pairingMessage = self.isPaired ? "配对成功，可以控制 Mac" : failureText
            self.statusText = self.pairingMessage
            self.canResetCurrentHostTrust = hasTrust
            if self.isPaired { self.rememberConnectedHost() }
            if !self.isPaired {
                self.isStreaming = false
                self.videoIsPlaying = false
                self.videoRenderer.reset()
            } else if self.wantsStreaming {
                self.isStreaming = false
                self.startStreaming()
            }
        }
    }

    func failTrust(_ reason: String, storageFailure: Bool = false) {
        if storageFailure { credentialStoreErrorText = reason }
        desiredEndpoint = nil
        wantsStreaming = false
        disconnectOnNetworkQueue()
        publishStatus(reason)
        let epoch = connectionEpoch.value
        Task { @MainActor [weak self] in
            guard let self, self.connectionEpoch.value == epoch else { return }
            self.isPairing = false
            self.isPaired = false
            self.isConnected = false
            self.isStreaming = false
            self.videoIsPlaying = false
            self.videoRenderer.reset()
            self.pairingMessage = reason
            self.canResetCurrentHostTrust = true
        }
    }
}
