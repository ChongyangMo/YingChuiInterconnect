import Foundation
import YingchuiProtocol

@MainActor
protocol AccountLinkAccount: AnyObject {
    var linkUserID: String? { get }
    var canReceiveAccount: Bool { get }
    func issueAccountGrant(clientID: String, challenge: String, userID: String) async throws -> AccountDeviceGrant
    func receiveAccountGrant(_ token: String, verifier: String, userID: String,
                             authorized: @escaping @MainActor () -> Bool) async throws
    func accountLinkFailed(_ message: String)
}

/// 只接收已通过证书与配对验证的通道；令牌留在各设备自己的钥匙串。
@MainActor
final class AccountLinkCoordinator {
    static let clientIDs: Set<String> = ["com.yingchui.interconnect.mac", "com.yingchui.interconnect.pad"]
    final class Peer {
        let lease: AccountLinkLease
        let clientID: String
        let send: (AccountLinkMessage) -> Void
        var state: AccountLinkMessage?
        var publishedUser: String?
        var publishedAccepts: Bool?
        var attempted = false
        var issued = false
        var task: Task<Void, Never>?
        init(lease: AccountLinkLease, clientID: String, send: @escaping (AccountLinkMessage) -> Void) {
            self.lease = lease; self.clientID = clientID; self.send = send
        }
    }
    struct Pending {
        let peer: Peer
        let id: UUID
        let userID: String
        let proof: AccountLinkProof
    }
    weak var account: (any AccountLinkAccount)?
    let clientID: String
    var peers: [UUID: Peer] = [:]
    var pending: Pending?
    var receiving: Task<Void, Never>?
    var deadline: Task<Void, Never>?
    var log: (String) -> Void = { _ in }

    init(account: any AccountLinkAccount, clientID: String = AccountConfiguration.defaultClientID) {
        self.account = account; self.clientID = clientID
    }

    func attach(_ lease: AccountLinkLease, clientID: String, send: @escaping (AccountLinkMessage) -> Void) {
        guard lease.isActive, Self.clientIDs.contains(clientID), clientID != self.clientID,
              peers[lease.id] == nil else { return }
        let peer = Peer(lease: lease, clientID: clientID, send: send)
        peers[lease.id] = peer
        publish(to: peer)
    }

    func detach(_ lease: AccountLinkLease) {
        lease.invalidate()
        peers.removeValue(forKey: lease.id)?.task?.cancel()
        if pending?.peer.lease.id == lease.id { cancelIncoming() }
    }

    func cancelPending() {
        cancelIncoming()
        for peer in peers.values { peer.task?.cancel(); peer.task = nil }
    }

    func cancelIncoming() {
        receiving?.cancel(); receiving = nil
        deadline?.cancel(); deadline = nil
        pending = nil
    }

    func accountChanged() {
        for peer in peers.values where peer.lease.isActive { publish(to: peer) }
        if pending == nil, account?.canReceiveAccount == true {
            for peer in peers.values where peer.lease.isActive && !peer.attempted {
                if let user = peer.state?.userID { request(from: peer, userID: user); break }
            }
        }
    }

    private func publish(to peer: Peer) {
        let user = account?.linkUserID
        let accepts = account?.canReceiveAccount == true
        guard peer.publishedAccepts != accepts || peer.publishedUser != user else { return }
        peer.publishedUser = user; peer.publishedAccepts = accepts
        peer.send(AccountLinkMessage(phase: .state, userID: user, acceptsLogin: accepts, clientID: clientID))
    }

    func receive(_ message: AccountLinkMessage, from lease: AccountLinkLease) {
        guard lease.isActive, let peer = peers[lease.id], message.isValid else { return }
        switch message.phase {
        case .state:
            guard message.clientID == peer.clientID else { return }
            if peer.state == nil { peer.publishedAccepts = nil }
            peer.state = message
            accountChanged()
        case .request:
            issue(message, to: peer)
        case .grant:
            redeem(message, from: peer)
        case .result:
            if message.id == pending?.id, pending?.peer === peer, message.errorCode != nil {
                failIncoming("另一台设备未能授权账号联动，请重新连接或手动登录。")
            }
        }
    }

    private func request(from peer: Peer, userID: String) {
        guard pending == nil, account?.canReceiveAccount == true else { return }
        peer.attempted = true
        do {
            let request = Pending(peer: peer, id: UUID(), userID: userID, proof: try AccountLinkProof())
            pending = request
            peer.send(AccountLinkMessage(phase: .request, id: request.id, userID: userID,
                                         clientID: clientID, challenge: request.proof.challenge))
            log("已向可信设备请求账号联动")
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self, self.pending?.id == request.id else { return }
                self.failIncoming("账号联动超时，请重新连接或手动登录。")
            }
        } catch { account?.accountLinkFailed(accountErrorMessage(error)) }
    }

    func failIncoming(_ message: String) {
        cancelIncoming()
        account?.accountLinkFailed(message)
        log(message)
    }
}
