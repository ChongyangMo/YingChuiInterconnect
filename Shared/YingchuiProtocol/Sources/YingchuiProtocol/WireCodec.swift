import Foundation

public enum WireCodecError: LocalizedError, Equatable {
    case emptyFrame
    case frameTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyFrame: "控制消息不能为空"
        case .frameTooLarge(let size): "控制消息超过大小限制（\(size) 字节）"
        }
    }
}

public enum WireCodec {
    public static func encode(_ message: WireMessage) throws -> Data {
        let payload = try JSONEncoder().encode(message)
        guard !payload.isEmpty else {
            throw WireCodecError.emptyFrame
        }
        guard payload.count <= YingchuiService.maximumFrameSize else {
            throw WireCodecError.frameTooLarge(payload.count)
        }

        var length = UInt32(payload.count).bigEndian
        var framed = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        framed.append(payload)
        return framed
    }
}

public struct WireMessageDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) throws -> [WireMessage] {
        buffer.append(data)
        var messages: [WireMessage] = []

        while buffer.count >= MemoryLayout<UInt32>.size {
            let payloadLength = buffer.prefix(4).reduce(0) { partial, byte in
                (partial << 8) | Int(byte)
            }

            guard payloadLength > 0 else {
                throw WireCodecError.emptyFrame
            }
            guard payloadLength <= YingchuiService.maximumFrameSize else {
                throw WireCodecError.frameTooLarge(payloadLength)
            }

            let frameLength = 4 + payloadLength
            guard buffer.count >= frameLength else {
                break
            }

            let payload = buffer.subdata(in: 4..<frameLength)
            // 新的可选消息种类可以跳过；已知消息字段损坏仍按协议错误终止。
            struct Header: Decodable { let kind: String }
            let header = try JSONDecoder().decode(Header.self, from: payload)
            if WireMessageKind(rawValue: header.kind) != nil {
                messages.append(try JSONDecoder().decode(WireMessage.self, from: payload))
            }
            buffer.removeSubrange(0..<frameLength)
        }

        return messages
    }
}
