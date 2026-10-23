import Foundation
import YingchuiProtocol

struct TrustedDeviceSummary: Identifiable {
    let id: String
    let name: String
    let connected: Bool
    let controlling: Bool
}

extension MacHostModel {
    func claimController(_ session: HostPeerSession) -> Bool {
        guard session.isAuthorized, !session.isSuperseded else { return false }
        guard controlSessionID == nil || controlSessionID == session.id else { return false }
        controlSessionID = session.id
        publishTrustedDevices()
        return true
    }

    /// 只有已验证配对凭据的同设备新连接可以替换旧会话。
    func retirePreviousSessions(for session: HostPeerSession) {
        guard session.isAuthorized, !session.isSuperseded, !session.deviceID.isEmpty else { return }
        let previous = sessions.values.filter {
            $0.id != session.id && $0.deviceID == session.deviceID && $0.isAuthorized
        }
        for old in previous {
            old.isSuperseded = true
            old.isAuthorized = false
            remove(old)
            old.cancel()
            eventLog.record("同一已认证设备重新连接，旧会话已释放：\(old.id)")
        }
    }

    func rememberDevice(_ session: HostPeerSession) {
        deviceNames[session.deviceID] = session.deviceName
        if persistsDeviceMetadata { UserDefaults.standard.set(deviceNames, forKey: "YingchuiTrustedDeviceNames") }
        publishTrustedDevices()
    }

    func publishTrustedDevices() {
        let devices = trustedDeviceTokens.keys.sorted().map { id in
            let matching = sessions.values.filter { $0.deviceID == id && $0.isAuthorized }
            return TrustedDeviceSummary(id: id, name: deviceNames[id] ?? "已配对设备",
                connected: !matching.isEmpty, controlling: matching.contains { $0.id == controlSessionID })
        }
        let controller = controlSessionID.flatMap { sessions[$0]?.deviceName }
        Task { @MainActor [weak self] in
            self?.trustedDevices = devices
            self?.activeControllerName = controller
        }
    }

    @MainActor
    func revokeDevice(_ id: String) {
        networkQueue.async { [weak self] in
            guard let self else { return }
            guard self.trustedDeviceTokens[id] != nil else { self.publishStatus("配对设备不存在"); return }
            var tokens = self.trustedDeviceTokens
            tokens.removeValue(forKey: id)
            do { try self.saveTrustedDevices(tokens) }
            catch { self.publishStatus("撤销设备失败：\(error.localizedDescription)"); return }
            self.trustedDeviceTokens = tokens
            self.deviceNames.removeValue(forKey: id)
            if self.persistsDeviceMetadata { UserDefaults.standard.set(self.deviceNames, forKey: "YingchuiTrustedDeviceNames") }
            for session in self.sessions.values where session.deviceID == id {
                self.releaseInputState(for: session)
                if self.streamingSessionID == session.id { self.stopStreaming() }
                if self.controlSessionID == session.id { self.controlSessionID = nil }
                session.isAuthorized = false
                self.detachAccountLink(session)
                session.send(WireMessage(kind: .pairResult, accepted: false, detail: "trust_revoked")) { session.cancel() }
            }
            self.publishPairedDeviceCount()
            self.publishTrustedDevices()
            self.publishStatus("已撤销设备授权")
        }
    }
}
