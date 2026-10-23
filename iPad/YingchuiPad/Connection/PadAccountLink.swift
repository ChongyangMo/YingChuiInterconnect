import Foundation
import YingchuiProtocol

extension PadConnectionModel {
    @MainActor
    func bindAccount(_ account: AccountModel) {
        linkedAccount = account
        account.accountLink.log = { [weak self] in self?.eventLog.record($0) }
        networkQueue.async { [weak self] in self?.attachAccountLink() }
    }

    func attachAccountLink() {
        guard accountLinkAuthorized, hostSupportsAccountLink, let connection else { return }
        let lease = accountLinkLease ?? AccountLinkLease()
        accountLinkLease = lease
        DispatchQueue.main.async { [weak self] in
            guard let self, lease.isActive else { return }
            self.linkedAccount?.accountLink.attach(lease, clientID: "com.yingchui.interconnect.mac") { [weak self] payload in
                self?.networkQueue.async { [weak self] in
                    guard let self, lease.isActive, self.accountLinkAuthorized,
                          self.accountLinkLease === lease, self.connection === connection else { return }
                    self.send(WireMessage(kind: .accountLink, accountLink: payload), over: connection)
                }
            }
        }
    }

    func detachAccountLink() {
        accountLinkAuthorized = false
        guard let lease = accountLinkLease else { return }
        lease.invalidate()
        accountLinkLease = nil
        DispatchQueue.main.async { [weak self] in self?.linkedAccount?.accountLink.detach(lease) }
    }

    func handleAccountLink(_ message: WireMessage) {
        guard accountLinkAuthorized, hostSupportsAccountLink,
              let lease = accountLinkLease, lease.isActive, let payload = message.accountLink else { return }
        DispatchQueue.main.async { [weak self] in
            self?.linkedAccount?.accountLink.receive(payload, from: lease)
        }
    }
}
