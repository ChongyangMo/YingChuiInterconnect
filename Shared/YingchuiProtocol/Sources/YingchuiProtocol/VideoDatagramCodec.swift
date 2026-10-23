import Foundation

public enum VideoDatagramCodec {
    public static let maximumWireDatagramSize = 1_200
    public static let authenticatedEncryptionOverhead = 28
    public static let maximumDatagramSize = maximumWireDatagramSize - authenticatedEncryptionOverhead
    public static let headerSize = 42
    public static let maximumPayloadSize = maximumDatagramSize - headerSize
    public static let maximumAccessUnitSize = 4_194_304
    public static let maximumFragmentsPerFrame =
        (maximumAccessUnitSize + maximumPayloadSize - 1) / maximumPayloadSize

    private static let magic: UInt32 = 0x59435631 // YCV1
    private static let version: UInt8 = 1

    public static func fragment(
        accessUnit: Data,
        streamID: UUID,
        frameID: UInt32,
        presentationTimeMicroseconds: UInt64,
        isKeyFrame: Bool
    ) throws -> [Data] {
        guard !accessUnit.isEmpty else { return [] }
        guard accessUnit.count <= maximumAccessUnitSize else {
            throw VideoDatagramError.accessUnitTooLarge(accessUnit.count)
        }
        let count = (accessUnit.count + maximumPayloadSize - 1) / maximumPayloadSize
        guard count <= maximumFragmentsPerFrame else { throw VideoDatagramError.tooManyFragments }

        return (0..<count).map { index in
            let start = index * maximumPayloadSize
            let end = min(start + maximumPayloadSize, accessUnit.count)
            let payload = accessUnit.subdata(in: start..<end)
            return encode(
                VideoFragment(
                    streamID: streamID,
                    frameID: frameID,
                    fragmentIndex: UInt16(index),
                    fragmentCount: UInt16(count),
                    presentationTimeMicroseconds: presentationTimeMicroseconds,
                    isKeyFrame: isKeyFrame,
                    payload: payload
                )
            )
        }
    }

    public static func encode(_ fragment: VideoFragment) -> Data {
        var data = Data(capacity: headerSize + fragment.payload.count)
        append(magic, to: &data)
        data.append(version)
        data.append(fragment.isKeyFrame ? 1 : 0)
        append(UInt16(headerSize), to: &data)
        withUnsafeBytes(of: fragment.streamID.uuid) { data.append(contentsOf: $0) }
        append(fragment.frameID, to: &data)
        append(fragment.fragmentIndex, to: &data)
        append(fragment.fragmentCount, to: &data)
        append(fragment.presentationTimeMicroseconds, to: &data)
        append(UInt16(fragment.payload.count), to: &data)
        data.append(fragment.payload)
        return data
    }

    public static func decode(_ data: Data) throws -> VideoFragment {
        guard data.count >= headerSize else { throw VideoDatagramError.datagramTooShort }
        guard data.count <= maximumDatagramSize else { throw VideoDatagramError.datagramTooLarge }
        guard readUInt32(data, at: 0) == magic else { throw VideoDatagramError.invalidMagic }
        guard data[4] == version else { throw VideoDatagramError.unsupportedVersion(data[4]) }
        guard readUInt16(data, at: 6) == UInt16(headerSize) else { throw VideoDatagramError.invalidHeader }

        let uuidBytes = Array(data[8..<24])
        let streamID = UUID(uuid: (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        ))
        let fragmentIndex = readUInt16(data, at: 28)
        let fragmentCount = readUInt16(data, at: 30)
        let payloadLength = Int(readUInt16(data, at: 40))
        guard fragmentCount > 0,
              Int(fragmentCount) <= maximumFragmentsPerFrame,
              fragmentIndex < fragmentCount else { throw VideoDatagramError.invalidHeader }
        guard payloadLength == data.count - headerSize else { throw VideoDatagramError.invalidPayloadLength }

        return VideoFragment(
            streamID: streamID,
            frameID: readUInt32(data, at: 24),
            fragmentIndex: fragmentIndex,
            fragmentCount: fragmentCount,
            presentationTimeMicroseconds: readUInt64(data, at: 32),
            isKeyFrame: data[5] & 1 == 1,
            payload: data.subdata(in: headerSize..<data.count)
        )
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        data[offset..<(offset + 2)].reduce(0) { ($0 << 8) | UInt16($1) }
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        data[offset..<(offset + 8)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

