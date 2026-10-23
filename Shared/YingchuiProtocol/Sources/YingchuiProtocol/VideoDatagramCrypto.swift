import Foundation
import CryptoKit

public enum VideoDatagramCryptoError: LocalizedError, Equatable {
    case invalidKeyLength
    case datagramTooLarge
    case authenticationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidKeyLength: "视频加密密钥长度无效"
        case .datagramTooLarge: "加密视频数据包超过网络安全上限"
        case .authenticationFailed: "视频数据包认证失败或已损坏"
        }
    }
}

public enum VideoDatagramCrypto {
    public static func makeKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    public static func seal(_ datagram: Data, key: Data) throws -> Data {
        guard key.count == 32 else { throw VideoDatagramCryptoError.invalidKeyLength }
        let sealed = try ChaChaPoly.seal(datagram, using: SymmetricKey(data: key))
        let combined = sealed.combined
        guard combined.count <= VideoDatagramCodec.maximumWireDatagramSize else {
            throw VideoDatagramCryptoError.datagramTooLarge
        }
        return combined
    }

    public static func open(_ datagram: Data, key: Data) throws -> Data {
        guard key.count == 32 else { throw VideoDatagramCryptoError.invalidKeyLength }
        guard datagram.count <= VideoDatagramCodec.maximumWireDatagramSize else {
            throw VideoDatagramCryptoError.datagramTooLarge
        }
        do {
            return try ChaChaPoly.open(
                ChaChaPoly.SealedBox(combined: datagram),
                using: SymmetricKey(data: key)
            )
        } catch {
            throw VideoDatagramCryptoError.authenticationFailed
        }
    }
}

