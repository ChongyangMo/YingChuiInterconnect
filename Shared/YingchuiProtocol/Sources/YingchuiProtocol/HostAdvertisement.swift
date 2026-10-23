import Foundation

public struct HostAdvertisement: Equatable, Sendable {
    public static let hostIDKey = "host-id"
    public static let protocolVersionKey = "protocol"

    public let hostID: String
    public let protocolVersion: Int
    public let minimumProtocolVersion: Int?
    public var isCompatible: Bool {
        WireProtocolCompatibility.negotiatedVersion(peerVersion: protocolVersion, peerMinimum: minimumProtocolVersion) != nil
    }

    public init?(txtRecord: [String: String]) {
        guard let hostID = txtRecord[Self.hostIDKey],
              UUID(uuidString: hostID) != nil,
              let protocolVersion = txtRecord[Self.protocolVersionKey].flatMap(Int.init) else {
            return nil
        }
        self.hostID = hostID
        self.protocolVersion = protocolVersion
        if let value = txtRecord["minimum-protocol"] {
            guard let minimum = Int(value), minimum > 0, minimum <= protocolVersion else { return nil }
            minimumProtocolVersion = minimum
        } else { minimumProtocolVersion = nil }
    }

    public init(hostID: String, protocolVersion: Int = YingchuiService.protocolVersion,
                minimumProtocolVersion: Int? = nil) {
        self.hostID = hostID
        self.protocolVersion = protocolVersion
        self.minimumProtocolVersion = minimumProtocolVersion
            ?? (protocolVersion == YingchuiService.protocolVersion ? WireProtocolCompatibility.minimumSupportedVersion : nil)
    }

    public var txtRecord: [String: String] {
        var record = [Self.hostIDKey: hostID, Self.protocolVersionKey: String(protocolVersion)]
        if let minimumProtocolVersion { record["minimum-protocol"] = String(minimumProtocolVersion) }
        return record
    }
}
