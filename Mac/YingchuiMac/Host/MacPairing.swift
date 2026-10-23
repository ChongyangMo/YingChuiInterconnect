import AppKit
import CoreGraphics
import Foundation
import Network
import Security
import YingchuiProtocol

extension MacHostModel {
    @MainActor
    func forgetPairedDevices() {
        networkQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.saveTrustedDevices([:])
                self.credentialStoreErrorText = nil
            } catch {
                self.credentialStoreErrorText = "移除可信设备失败：\(error.localizedDescription)"
                self.publishStatus(self.credentialStoreErrorText ?? "移除可信设备失败")
                return
            }
            self.trustedDeviceTokens.removeAll()
            self.deviceNames.removeAll()
            self.controlSessionID = nil
            UserDefaults.standard.removeObject(forKey: "YingchuiTrustedDeviceNames")
            self.publishTrustedDevices()
            self.stopStreaming()
            for session in self.sessions.values {
                self.releaseInputState(for: session)
                session.isAuthorized = false
                self.detachAccountLink(session)
                session.send(WireMessage(kind: .pairResult, accepted: false, detail: "trust_revoked"))
            }
            self.publishPairedDeviceCount()
            self.rotatePairingCode()
            self.publishStatus("已移除全部可信设备")
        }
    }

    func handleHello(_ message: WireMessage, from session: HostPeerSession) {
        guard !session.didReceiveHello else {
            session.send(WireMessage(kind: .error, detail: "duplicate_hello")) { session.cancel() }
            return
        }
        session.didReceiveHello = true
        session.supportsAccountLink = message.supportsAccountLink == true
        let deviceID = message.deviceID ?? ""
        session.deviceID = deviceID
        session.isAuthorized = !deviceID.isEmpty
            && message.sessionToken != nil
            && trustedDeviceTokens[deviceID] == message.sessionToken
        let clientName = String((message.deviceName ?? "iPad").prefix(80))
        session.deviceName = clientName
        if session.isAuthorized {
            retirePreviousSessions(for: session)
            rememberDevice(session)
        }

        Task { @MainActor [weak self] in
            self?.lastClientName = clientName
        }
        session.send(
            WireMessage(
                id: message.id,
                kind: .hello,
                deviceName: Host.current().localizedName ?? "Mac mini",
                hostID: hostID,
                accepted: session.isAuthorized,
                supportsTouch: true,
                supportsTouchHover: true,
                supportsAccountLink: true,
                minimumProtocolVersion: WireProtocolCompatibility.minimumSupportedVersion
            )
        )
        attachAccountLink(session)
    }

    func handlePairRequest(_ message: WireMessage, from session: HostPeerSession) {
        do {
            try pairingPolicy.consumeAttempt(at: ProcessInfo.processInfo.systemUptime)
        } catch {
            let detail = (error as? PairingAttemptError)?.rawValue ?? "pairing_rate_limited"
            session.send(WireMessage(id: message.id, kind: .pairResult, accepted: false, detail: detail))
            publishStatus(error.localizedDescription)
            return
        }
        guard let deviceID = message.deviceID,
              !deviceID.isEmpty,
              deviceID == session.deviceID,
              message.pairingCode == pairingCode else {
            session.send(WireMessage(id: message.id, kind: .pairResult, accepted: false, detail: "invalid_pairing_code"))
            return
        }

        let sessionToken: String
        var updatedTokens = trustedDeviceTokens
        do {
            sessionToken = try Self.makeSessionToken()
            updatedTokens[deviceID] = sessionToken
            try saveTrustedDevices(updatedTokens)
            credentialStoreErrorText = nil
        } catch {
            credentialStoreErrorText = "保存配对凭据失败：\(error.localizedDescription)"
            session.send(WireMessage(id: message.id, kind: .pairResult, accepted: false, detail: "credential_store_failed"))
            publishStatus(credentialStoreErrorText ?? "保存配对凭据失败")
            return
        }
        trustedDeviceTokens = updatedTokens
        session.isAuthorized = true
        retirePreviousSessions(for: session)
        rememberDevice(session)
        publishPairedDeviceCount()
        session.send(
            WireMessage(
                id: message.id,
                kind: .pairResult,
                accepted: true,
                detail: "paired",
                sessionToken: sessionToken
            )
        )
        attachAccountLink(session)
        rotatePairingCode()
        publishStatus("新设备配对成功")
    }

    func rotatePairingCode() {
        let newCode = Self.makePairingCode()
        pairingCode = newCode
        pairingPolicy.rotateCode(at: ProcessInfo.processInfo.systemUptime)
        Task { @MainActor [weak self] in
            self?.pairingCodeText = newCode
        }
    }

    static func makePairingCode() -> String {
        return String(format: "%06d", Int.random(in: 0...999_999))
    }

    static func makeSessionToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw HostSecurityError.randomGeneration(status)
        }
        return Data(bytes).base64EncodedString()
    }

    func saveTrustedDevices(_ values: [String: String]) throws {
        if let trustedDeviceWriter { try trustedDeviceWriter(values); return }
        try SecureDictionaryStore.save(
            values,
            service: Self.secureStoreService,
            account: Self.secureStoreAccount
        )
    }
}
