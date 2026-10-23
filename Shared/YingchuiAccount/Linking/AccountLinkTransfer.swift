import Foundation
import YingchuiProtocol

extension AccountLinkCoordinator {
    func issue(_ message: AccountLinkMessage, to peer: Peer) {
        guard !peer.issued, peer.task == nil, let account,
              let userID = account.linkUserID, message.userID == userID,
              message.clientID == peer.clientID, let challenge = message.challenge,
              peer.state?.acceptsLogin == true, peer.state?.userID == nil else { return }
        // 同一可信连接只签发一次，防止重复消息制造会话或错误重试循环。
        peer.issued = true
        peer.task = Task { [weak self, weak peer] in
            guard let self, let peer else { return }
            defer { peer.task = nil }
            do {
                let grant = try await account.issueAccountGrant(clientID: peer.clientID,
                                                                challenge: challenge, userID: userID)
                try Task.checkCancellation()
                guard peer.lease.isActive, account.linkUserID == userID,
                      grant.userID == userID else { throw CancellationError() }
                let remaining = Int(grant.expiresAt.timeIntervalSinceNow.rounded(.down))
                guard remaining > 0 else { throw AccountError.expired }
                peer.send(AccountLinkMessage(phase: .grant, id: message.id, userID: userID,
                                             grant: grant.token, expiresIn: min(remaining, 60)))
                self.log("已为可信设备签发一次性账号授权")
            } catch is CancellationError {
                // 信任或账号已变化，不能继续发送授权。
            } catch {
                guard peer.lease.isActive else { return }
                peer.send(AccountLinkMessage(phase: .result, id: message.id, errorCode: "authorization_failed"))
                let text = "账号联动失败：\(accountErrorMessage(error))"
                account.accountLinkFailed(text)
                self.log(text)
            }
        }
    }

    func redeem(_ message: AccountLinkMessage, from peer: Peer) {
        guard receiving == nil, let pending, pending.peer === peer, pending.id == message.id,
              message.userID == pending.userID, let token = message.grant,
              let account, account.canReceiveAccount else { return }
        receiving = Task { [weak self] in
            guard let self else { return }
            do {
                try await account.receiveAccountGrant(token, verifier: pending.proof.verifier,
                                                       userID: pending.userID) { [weak self] in
                    peer.lease.isActive && self?.pending?.id == pending.id
                }
                try Task.checkCancellation()
                guard peer.lease.isActive, self.pending?.id == pending.id else { throw CancellationError() }
                peer.send(AccountLinkMessage(phase: .result, id: pending.id))
                self.cancelIncoming()
                self.log("账号联动登录成功，已保存本机独立会话")
                self.accountChanged()
            } catch is CancellationError {
                if self.pending?.id == pending.id { self.cancelIncoming() }
            } catch {
                guard self.pending?.id == pending.id else { return }
                self.failIncoming("账号联动失败：\(accountErrorMessage(error))")
                self.accountChanged()
            }
        }
    }
}
