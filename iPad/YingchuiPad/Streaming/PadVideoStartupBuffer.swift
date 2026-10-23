import Foundation
import YingchuiProtocol

/// 仅暂存密文；通过流编号和密钥认证后才能交给视频组装器。
struct PadVideoStartupBuffer {
    enum Failure: LocalizedError {
        case full
        var errorDescription: String? { "视频配置等待缓冲区已满" }
    }

    private var packets: [UUID: [Data]] = [:]
    private(set) var byteCount = 0
    private(set) var packetCount = 0
    private let maximumBytes: Int
    private let maximumPackets: Int

    init(maximumBytes: Int = 4 * 1_024 * 1_024, maximumPackets: Int = 4_096) {
        self.maximumBytes = maximumBytes
        self.maximumPackets = maximumPackets
    }

    mutating func append(_ data: Data, candidate: UUID) throws {
        guard !data.isEmpty, data.count <= VideoDatagramCodec.maximumWireDatagramSize else {
            throw VideoDatagramCryptoError.datagramTooLarge
        }
        guard packetCount < maximumPackets, data.count <= maximumBytes - byteCount else {
            throw Failure.full
        }
        packets[candidate, default: []].append(data)
        byteCount += data.count
        packetCount += 1
    }

    mutating func take(_ candidate: UUID) -> [Data] {
        let result = packets.removeValue(forKey: candidate) ?? []
        byteCount -= result.reduce(0) { $0 + $1.count }
        packetCount -= result.count
        return result
    }

    mutating func reset() {
        packets.removeAll()
        byteCount = 0
        packetCount = 0
    }
}
