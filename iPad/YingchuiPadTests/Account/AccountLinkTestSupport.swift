import Foundation
import CryptoKit
import YingchuiProtocol
@testable import YingchuiPad

@MainActor
final class LinkTestServer {
    struct Grant { let user: AccountUser; let challenge: String; let client: String }
    var grants: [String: Grant] = [:]
    var issued = 0
    var exchanges = 0
    var deferExchange = false
    var continuation: CheckedContinuation<Void, Never>?
    let user = AccountUser(id: "linked-user", nickname: "联动测试", email: "link@example.com")
    func session(_ client: String, user: AccountUser? = nil) -> AccountSession {
        AccountSession(user: user ?? self.user, sessionID: "session-\(client)", accessToken: "access-\(client)",
                       refreshToken: "refresh-\(client)", accessExpiresAt: Date().addingTimeInterval(900),
                       refreshExpiresAt: Date().addingTimeInterval(86_400), appleUserID: nil)
    }
}

@MainActor
final class LinkTestService: AccountService {
    let server: LinkTestServer
    let client: String
    var available = true
    var confirmedUser: AccountUser?
    var availabilityMessage: String? { nil }
    init(_ server: LinkTestServer, client: String) { self.server = server; self.client = client }
    func status() async throws -> AccountServiceStatus {
        .init(emailAvailable: true, appleAvailable: false, deviceLinkAvailable: available)
    }
    func currentUser(accessToken: String) async throws -> AccountUser { confirmedUser ?? server.user }
    func createDeviceLink(accessToken: String, recipientClientID: String, challenge: String) async throws -> AccountDeviceGrant {
        server.issued += 1
        let token = UUID().uuidString
        server.grants[token] = .init(user: server.user, challenge: challenge, client: recipientClientID)
        return .init(token: token, userID: server.user.id, expiresAt: Date().addingTimeInterval(60))
    }
    func exchangeDeviceLink(grant: String, verifier: String) async throws -> AccountSession {
        server.exchanges += 1
        guard let value = server.grants.removeValue(forKey: grant), value.client == client,
              value.challenge == AccountLinkProof.base64url(Data(SHA256.hash(data: Data(verifier.utf8)))) else {
            throw AccountError.unauthorized
        }
        if server.deferExchange { await withCheckedContinuation { server.continuation = $0 } }
        return server.session(client)
    }
    func login(email: String, code: String) async throws -> AccountSession { server.session(client) }
    func revoke(refreshToken: String) async throws {}
    func refresh(refreshToken: String) async throws -> AccountSession { throw AccountError.invalidResponse }
    func sendEmailCode(email: String) async throws -> EmailCodeReceipt { throw AccountError.invalidResponse }
    func appleChallenge() async throws -> AppleAccountChallenge { throw AccountError.invalidResponse }
    func exchangeApple(challenge: AppleAccountChallenge, credential: AppleAccountCredential) async throws -> AccountSession {
        throw AccountError.invalidResponse
    }
}

@MainActor
final class LinkTestPair {
    let server = LinkTestServer()
    let mac: AccountModel
    let pad: AccountModel
    let macService: LinkTestService
    let padService: LinkTestService
    let macStore: AccountMemoryStore
    let padStore: AccountMemoryStore
    let macLease = AccountLinkLease()
    let padLease = AccountLinkLease()
    var messages: [(Bool, AccountLinkMessage)] = []
    var history: [AccountLinkMessage] = []
    let preferenceName = "AccountLinkTests.\(UUID())"
    let preferences: UserDefaults
    let macPreferences: UserDefaults
    init(donorMac: Bool = true, bothLoggedIn: Bool = false) {
        preferences = UserDefaults(suiteName: preferenceName)!
        macPreferences = UserDefaults(suiteName: preferenceName + ".mac")!
        macService = LinkTestService(server, client: "com.yingchui.interconnect.mac")
        padService = LinkTestService(server, client: "com.yingchui.interconnect.pad")
        macStore = AccountMemoryStore(donorMac || bothLoggedIn ? AccountRecord(session: server.session(macService.client)) : nil)
        padStore = AccountMemoryStore(!donorMac || bothLoggedIn ? AccountRecord(session: server.session(padService.client)) : nil)
        mac = AccountModel(service: macService, store: macStore, preferences: macPreferences)
        pad = AccountModel(service: padService, store: padStore, preferences: preferences)
        mac.accountLink = AccountLinkCoordinator(account: mac, clientID: macService.client)
        pad.accountLink = AccountLinkCoordinator(account: pad, clientID: padService.client)
    }
    func start() {
        mac.restoreOnce(); pad.restoreOnce()
        mac.accountLink.attach(macLease, clientID: padService.client) { [weak self] in self?.messages.append((false, $0)) }
        pad.accountLink.attach(padLease, clientID: macService.client) { [weak self] in self?.messages.append((true, $0)) }
    }
    func step() async {
        let batch = messages
        messages.removeAll()
        for (toMac, message) in batch {
            history.append(message)
            if toMac { mac.accountLink.receive(message, from: macLease) }
            else { pad.accountLink.receive(message, from: padLease) }
        }
        await Task.yield()
    }
    func cleanup() {
        mac.cancel(); pad.cancel()
        mac.accountLink.detach(macLease); pad.accountLink.detach(padLease)
        preferences.removePersistentDomain(forName: preferenceName)
        macPreferences.removePersistentDomain(forName: preferenceName + ".mac")
    }
}
