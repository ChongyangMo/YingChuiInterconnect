import Foundation

public enum USBPacketKind: UInt8, Sendable { case introduction = 1, control = 2, video = 3, audio = 4 }

public struct USBPacket: Sendable {
    public let kind: USBPacketKind
    public let payload: Data
    public init(kind: USBPacketKind, payload: Data) { self.kind = kind; self.payload = payload }
}

public enum USBPacketError: LocalizedError {
    case invalidFrame, invalidIntroduction, bufferFull
    public var errorDescription: String? {
        switch self {
        case .invalidFrame: "USB 数据帧无效或超过限制"
        case .invalidIntroduction: "USB 主机介绍无效或协议不兼容"
        case .bufferFull: "USB 传输积压超过限制"
        }
    }
}

public enum USBPacketCodec {
    public static let maximumPayload = 65_536
    public static func encode(_ packet: USBPacket) throws -> Data {
        guard !packet.payload.isEmpty, packet.payload.count <= maximumPayload else { throw USBPacketError.invalidFrame }
        var size = UInt32(packet.payload.count + 1).bigEndian
        var data = withUnsafeBytes(of: &size) { Data($0) }
        data.append(packet.kind.rawValue)
        data.append(packet.payload)
        return data
    }
}

public struct USBPacketDecoder: Sendable {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> [USBPacket] {
        guard buffer.count + data.count <= USBPacketCodec.maximumPayload * 3 else { throw USBPacketError.bufferFull }
        buffer.append(data)
        var result: [USBPacket] = []
        while buffer.count >= 5 {
            let size = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard size > 1, size <= USBPacketCodec.maximumPayload + 1,
                  let kind = USBPacketKind(rawValue: buffer[buffer.startIndex + 4]) else { throw USBPacketError.invalidFrame }
            guard buffer.count >= size + 4 else { break }
            result.append(USBPacket(kind: kind, payload: Data(buffer.dropFirst(5).prefix(size-1))))
            buffer.removeFirst(size+4)
        }
        return result
    }
}

public struct USBHostIntroduction: Codable, Sendable {
    public let transport: String
    public let hostID: String
    public let name: String
    public let protocolVersion: Int
    public let minimumProtocolVersion: Int
    public init(hostID: String, name: String) {
        transport = "YingchuiUSB1"
        self.hostID = hostID; self.name = name
        protocolVersion = YingchuiService.protocolVersion
        minimumProtocolVersion = WireProtocolCompatibility.minimumSupportedVersion
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4_096 else { throw USBPacketError.invalidIntroduction }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.transport == "YingchuiUSB1", UUID(uuidString: value.hostID) != nil,
              !value.name.isEmpty, value.name.utf8.count <= 256,
              WireProtocolCompatibility.negotiatedVersion(peerVersion: value.protocolVersion, peerMinimum: value.minimumProtocolVersion) != nil
        else { throw USBPacketError.invalidIntroduction }
        return value
    }
}
