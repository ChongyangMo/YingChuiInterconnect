import CryptoKit
import Foundation
import Security

struct AccountDeviceGrant: Sendable {
    let token: String
    let userID: String
    let expiresAt: Date
}

struct AccountLinkProof: Sendable {
    let verifier: String
    var challenge: String { Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    init() throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard result == errSecSuccess else { throw AccountError.keychain(result) }
        verifier = Self.base64url(Data(bytes))
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
