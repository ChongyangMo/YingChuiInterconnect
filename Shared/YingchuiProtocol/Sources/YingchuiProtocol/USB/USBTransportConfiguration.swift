import Foundation

public struct USBTransportConfiguration: Codable, Sendable {
    public let enabled: Bool
    public let devicePort: UInt16
    public init(enabled: Bool = true, devicePort: UInt16 = 38_457) {
        self.enabled = enabled; self.devicePort = devicePort
    }
    public static func load() throws -> Self {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.yingchui.interconnect")
            .appendingPathComponent("Transport")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("usb.json")
        if !FileManager.default.fileExists(atPath: file.path) {
            let initial = Self()
            try JSONEncoder().encode(initial).write(to: file, options: .atomic)
            return initial
        }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        guard value.devicePort > 1_024 else { throw USBPacketError.invalidIntroduction }
        return value
    }
}
