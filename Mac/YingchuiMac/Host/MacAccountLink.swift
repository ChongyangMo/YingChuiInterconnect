import Foundation
import YingchuiProtocol

extension MacHostModel {
    @MainActor
    func bindAccount(_ account: AccountModel) {
        linkedAccount = account
        account.accountLink.log = { [weak self] in self?.eventLog.record($0) }
        networkQueue.async { [weak self] in
            guard let self else { return }
            for session in self.sessions.values { self.attachAccountLink(session) }
        }
    }

    func attachAccountLink(_ session: HostPeerSession) {
        guard session.isAuthorized, session.supportsAccountLink else { return }
        let lease = session.accountLinkLease ?? AccountLinkLease()
        session.accountLinkLease = lease
        DispatchQueue.main.async { [weak self] in
            guard let self, lease.isActive else { return }
            self.linkedAccount?.accountLink.attach(lease, clientID: "com.yingchui.interconnect.pad") { [weak self] payload in
                self?.networkQueue.async { [weak self] in
                    guard let self, lease.isActive, self.sessions[session.id] === session,
                          session.isAuthorized, session.accountLinkLease === lease else { return }
                    session.send(WireMessage(kind: .accountLink, accountLink: payload))
                }
            }
        }
    }

    func detachAccountLink(_ session: HostPeerSession) {
        guard let lease = session.accountLinkLease else { return }
        lease.invalidate()
        session.accountLinkLease = nil
        DispatchQueue.main.async { [weak self] in self?.linkedAccount?.accountLink.detach(lease) }
    }

    func handleAccountLink(_ message: WireMessage, from session: HostPeerSession) {
        guard session.isAuthorized, session.supportsAccountLink,
              let lease = session.accountLinkLease, lease.isActive, let payload = message.accountLink else { return }
        DispatchQueue.main.async { [weak self] in
            self?.linkedAccount?.accountLink.receive(payload, from: lease)
        }
    }
}
