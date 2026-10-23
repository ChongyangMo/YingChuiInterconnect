import Foundation

struct MacInstallationIdentity {
    private struct Record: Codable { let installationID: UUID }
    static func load(at url: URL) throws -> String {
        if FileManager.default.fileExists(atPath: url.path) {
            do { return try JSONDecoder().decode(Record.self, from: Data(contentsOf: url)).installationID.uuidString.lowercased() }
            catch { throw MacManagementError.identity }
        }
        let record = Record(installationID: UUID())
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        return record.installationID.uuidString.lowercased()
    }

    static func applicationURL() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("com.yingchui.interconnect.mac/Management/installation.json")
    }
}
