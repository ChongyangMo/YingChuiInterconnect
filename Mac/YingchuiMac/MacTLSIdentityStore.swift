import Foundation
import Security

struct MacTLSIdentityLoadResult {
    let identity: SecIdentity
    let didRebuildAfterAuthorizationFailure: Bool
}

enum MacTLSIdentityStore {
    private static let keyTag = Data("com.yingchui.interconnect.mac.tls-key.v1".utf8)
    private static let activeKeyTagDefaultsKey = "YingchuiTLSActiveKeyTag"
    private static let certificateDefaultsKey = "YingchuiTLSCertificateDER"

    static func loadOrCreate() throws -> MacTLSIdentityLoadResult {
        let activeTag = UserDefaults.standard.data(forKey: activeKeyTagDefaultsKey) ?? keyTag
        do {
            return MacTLSIdentityLoadResult(
                identity: try loadOrCreateIdentity(keyTag: activeTag),
                didRebuildAfterAuthorizationFailure: false
            )
        } catch {
            guard isAuthorizationFailure(error) else { throw error }

            let replacementTag = Data(
                "com.yingchui.interconnect.mac.tls-key.\(UUID().uuidString)".utf8
            )
            UserDefaults.standard.set(replacementTag, forKey: activeKeyTagDefaultsKey)
            UserDefaults.standard.removeObject(forKey: certificateDefaultsKey)
            do {
                return MacTLSIdentityLoadResult(
                    identity: try loadOrCreateIdentity(keyTag: replacementTag),
                    didRebuildAfterAuthorizationFailure: true
                )
            } catch {
                throw TLSIdentityError.rebuildFailed(error.localizedDescription)
            }
        }
    }

    static func isAuthorizationFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain,
           nsError.code == Int(errSecAuthFailed) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isAuthorizationFailure(underlying)
        }
        return false
    }

    private static func loadOrCreateIdentity(keyTag: Data) throws -> SecIdentity {
        let privateKey = try loadPrivateKey(keyTag: keyTag) ?? createPrivateKey(keyTag: keyTag)
        let certificate: SecCertificate
        if let saved = UserDefaults.standard.data(forKey: certificateDefaultsKey),
           let existing = SecCertificateCreateWithData(kCFAllocatorDefault, saved as CFData),
           try certificateMatchesPrivateKey(existing, privateKey: privateKey) {
            certificate = existing
        } else {
            let data = try createSelfSignedCertificate(privateKey: privateKey)
            guard let created = SecCertificateCreateWithData(kCFAllocatorDefault, data as CFData) else {
                throw TLSIdentityError.invalidCertificate
            }
            certificate = created
            UserDefaults.standard.set(data, forKey: certificateDefaultsKey)
        }

        try ensureCertificateStored(certificate)

        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(nil, certificate, &identity)
        guard status == errSecSuccess, let identity else {
            throw TLSIdentityError.identity(status)
        }
        return identity
    }

    private static func certificateMatchesPrivateKey(
        _ certificate: SecCertificate,
        privateKey: SecKey
    ) throws -> Bool {
        guard let expectedPublicKey = SecKeyCopyPublicKey(privateKey),
              let certificatePublicKey = SecCertificateCopyKey(certificate) else {
            throw TLSIdentityError.invalidPrivateKey
        }
        var expectedError: Unmanaged<CFError>?
        guard let expectedData = SecKeyCopyExternalRepresentation(expectedPublicKey, &expectedError) as Data? else {
            throw expectedError?.takeRetainedValue() ?? TLSIdentityError.keyGeneration
        }
        var certificateError: Unmanaged<CFError>?
        guard let certificateData = SecKeyCopyExternalRepresentation(certificatePublicKey, &certificateError) as Data? else {
            throw certificateError?.takeRetainedValue() ?? TLSIdentityError.invalidCertificate
        }
        return expectedData == certificateData
    }

    private static func ensureCertificateStored(_ certificate: SecCertificate) throws {
        let status = SecItemAdd([
            kSecClass: kSecClassCertificate,
            kSecValueRef: certificate,
            kSecAttrLabel: "鹰锤互联本机 TLS 证书"
        ] as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw TLSIdentityError.certificateStorage(status)
        }
    }

    private static func loadPrivateKey(keyTag: Data) throws -> SecKey? {
        let query = [
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: keyTag,
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef: true
        ] as CFDictionary
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let item else {
            throw TLSIdentityError.keychain(status)
        }
        guard CFGetTypeID(item) == SecKeyGetTypeID() else {
            throw TLSIdentityError.invalidPrivateKey
        }
        return (item as! SecKey)
    }

    private static func createPrivateKey(keyTag: Data) throws -> SecKey {
        let attributes = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecAttrIsPermanent: true,
            kSecAttrApplicationTag: keyTag,
            kSecAttrLabel: "鹰锤互联本机 TLS 密钥"
        ] as CFDictionary
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes, &error) else {
            throw error?.takeRetainedValue() ?? TLSIdentityError.keyGeneration
        }
        return key
    }

    private static func createSelfSignedCertificate(privateKey: SecKey) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else { throw TLSIdentityError.keyGeneration }
        var externalError: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &externalError) as Data? else {
            throw externalError?.takeRetainedValue() ?? TLSIdentityError.keyGeneration
        }

        let signatureAlgorithm = DER.sequence(DER.oid([1, 2, 840, 10045, 4, 3, 2]))
        let commonName = DER.sequence(
            DER.set(
                DER.sequence(
                    DER.oid([2, 5, 4, 3]),
                    DER.utf8String("Yingchui Mac Local Host")
                )
            )
        )
        let validity = DER.sequence(
            DER.generalizedTime(Date().addingTimeInterval(-86_400)),
            DER.generalizedTime(Date().addingTimeInterval(10 * 365 * 86_400))
        )
        let publicKeyAlgorithm = DER.sequence(
            DER.oid([1, 2, 840, 10045, 2, 1]),
            DER.oid([1, 2, 840, 10045, 3, 1, 7])
        )
        let subjectPublicKeyInfo = DER.sequence(publicKeyAlgorithm, DER.bitString(publicKeyData))

        var serial = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial) == errSecSuccess else {
            throw TLSIdentityError.keyGeneration
        }
        serial[0] &= 0x7f
        if serial.allSatisfy({ $0 == 0 }) { serial[serial.count - 1] = 1 }

        let tbsCertificate = DER.sequence(
            DER.context0(DER.integer(Data([2]))),
            DER.integer(Data(serial)),
            signatureAlgorithm,
            commonName,
            validity,
            commonName,
            subjectPublicKeyInfo
        )
        var signatureError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            tbsCertificate as CFData,
            &signatureError
        ) as Data? else {
            throw signatureError?.takeRetainedValue() ?? TLSIdentityError.signature
        }
        return DER.sequence(tbsCertificate, signatureAlgorithm, DER.bitString(signature))
    }
}

private enum TLSIdentityError: LocalizedError {
    case keychain(OSStatus)
    case identity(OSStatus)
    case certificateStorage(OSStatus)
    case invalidPrivateKey
    case keyGeneration
    case signature
    case invalidCertificate
    case rebuildFailed(String)

    var errorDescription: String? {
        switch self {
        case .keychain(let status): "无法读取 TLS 密钥（\(status)）"
        case .identity(let status): "无法创建 TLS 身份（\(status)）"
        case .certificateStorage(let status): "无法保存 TLS 证书（\(status)）"
        case .invalidPrivateKey: "Keychain 中的 TLS 私钥类型无效"
        case .keyGeneration: "无法生成 TLS 密钥"
        case .signature: "无法签发本机 TLS 证书"
        case .invalidCertificate: "生成的 TLS 证书无效"
        case .rebuildFailed(let detail): "TLS 安全身份重建失败：\(detail)"
        }
    }
}

private enum DER {
    static func sequence(_ values: Data...) -> Data { tagged(0x30, concatenate(values)) }
    static func set(_ values: Data...) -> Data { tagged(0x31, concatenate(values)) }
    static func context0(_ value: Data) -> Data { tagged(0xa0, value) }
    static func utf8String(_ value: String) -> Data { tagged(0x0c, Data(value.utf8)) }
    static func bitString(_ value: Data) -> Data { tagged(0x03, Data([0]) + value) }

    static func integer(_ value: Data) -> Data {
        var bytes = value
        while bytes.count > 1, bytes.first == 0, bytes[bytes.index(after: bytes.startIndex)] & 0x80 == 0 {
            bytes.removeFirst()
        }
        if let first = bytes.first, first & 0x80 != 0 {
            bytes.insert(0, at: 0)
        }
        return tagged(0x02, bytes)
    }

    static func oid(_ components: [UInt64]) -> Data {
        precondition(components.count >= 2)
        var bytes = [UInt8(components[0] * 40 + components[1])]
        for component in components.dropFirst(2) {
            var value = component
            var encoded = [UInt8(value & 0x7f)]
            value >>= 7
            while value > 0 {
                encoded.insert(UInt8(value & 0x7f) | 0x80, at: 0)
                value >>= 7
            }
            bytes.append(contentsOf: encoded)
        }
        return tagged(0x06, Data(bytes))
    }

    static func generalizedTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        return tagged(0x18, Data(formatter.string(from: date).utf8))
    }

    private static func tagged(_ tag: UInt8, _ value: Data) -> Data {
        Data([tag]) + length(value.count) + value
    }

    private static func length(_ value: Int) -> Data {
        if value < 128 { return Data([UInt8(value)]) }
        var value = value
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    private static func concatenate(_ values: [Data]) -> Data {
        values.reduce(into: Data()) { $0.append($1) }
    }
}
