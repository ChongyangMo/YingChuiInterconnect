import Foundation

public struct AudioPacket: Sendable, Equatable {
    public let streamID: UUID
    public let sequence: UInt32
    public let pcm: Data
    public var frameCount: Int { pcm.count / 4 }
    public init(streamID: UUID, sequence: UInt32, pcm: Data) {
        self.streamID = streamID; self.sequence = sequence; self.pcm = pcm
    }
}

/// 固定 48 kHz、双声道、有符号 16 位小端 PCM；单包最多 5 ms。
public enum AudioPacketCodec {
    public static let sampleRate = 48_000
    public static let channels = 2
    public static let maximumFrames = 240
    public static let headerSize = 26

    public static func encode(_ packet: AudioPacket) throws -> Data {
        guard packet.frameCount > 0, packet.frameCount <= maximumFrames, packet.pcm.count % 4 == 0 else {
            throw AudioPacketError.invalidPacket
        }
        var data = Data([0x59, 0x43, 0x41, 0x01])
        var uuid = packet.streamID.uuid
        withUnsafeBytes(of: &uuid) { data.append(contentsOf: $0) }
        var sequence = packet.sequence.bigEndian
        withUnsafeBytes(of: &sequence) { data.append(contentsOf: $0) }
        var count = UInt16(packet.frameCount).bigEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        data.append(packet.pcm)
        return data
    }

    public static func decode(_ data: Data) throws -> AudioPacket {
        let bytes = [UInt8](data)
        guard bytes.count >= headerSize, Array(bytes[0..<4]) == [0x59, 0x43, 0x41, 0x01] else {
            throw AudioPacketError.invalidPacket
        }
        let id = UUID(uuid: (bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                             bytes[12], bytes[13], bytes[14], bytes[15], bytes[16], bytes[17], bytes[18], bytes[19]))
        let sequence = bytes[20..<24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let frames = Int(bytes[24]) << 8 | Int(bytes[25])
        guard (1...maximumFrames).contains(frames), bytes.count == headerSize + frames * 4 else {
            throw AudioPacketError.invalidPacket
        }
        return AudioPacket(streamID: id, sequence: sequence, pcm: Data(bytes[headerSize...]))
    }
}

public enum AudioPacketError: LocalizedError {
    case invalidPacket, unsupportedFormat, queueFull
    public var errorDescription: String? {
        switch self {
        case .invalidPacket: "声音数据包格式无效"
        case .unsupportedFormat: "声音采样格式不受支持"
        case .queueFull: "声音队列已满，请检查网络或设备负载"
        }
    }
}
