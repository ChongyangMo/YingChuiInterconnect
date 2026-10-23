import Foundation

/// 调用者负责串行访问；日志最多保留三份，每份默认 2 MB。
public final class RuntimeJournal {
    public struct Session: Codable, Sendable {
        public let id: UUID
        public let processID: Int32
        public let startedAt: Date
        public var lastSeenAt: Date
        public var phase: String
        public var endedNormally: Bool
    }

    public let directory: URL
    private let maximumBytes: Int
    private var handle: FileHandle?
    private var byteCount = 0
    private let formatter = ISO8601DateFormatter()

    public init(directory: URL, maximumBytes: Int = 2 * 1024 * 1024) throws {
        guard maximumBytes > 0 else { throw CocoaError(.fileWriteInvalidFileName) }
        self.directory = directory
        self.maximumBytes = maximumBytes
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func previousSession() throws -> Session? {
        let path = directory.appendingPathComponent("session.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try JSONDecoder().decode(Session.self, from: Data(contentsOf: path))
    }

    public func checkpoint(_ session: Session) throws {
        try JSONEncoder().encode(session).write(to: directory.appendingPathComponent("session.json"), options: .atomic)
    }

    public func append(_ message: String, at date: Date = Date()) throws {
        // 限制单条记录大小；保留明确标记，避免单条异常信息撑爆文件。
        let bounded = message.count > 4096 ? String(message.prefix(4096)) + "［日志过长，已截断］" : message
        let data = Data("\(formatter.string(from: date)) \(bounded.replacingOccurrences(of: "\n", with: "\\n"))\n".utf8)
        if handle == nil { try openCurrent() }
        if byteCount > 0, byteCount + data.count > maximumBytes { try rotate() }
        try handle?.write(contentsOf: data)
        byteCount += data.count
    }

    public func synchronize() throws { try handle?.synchronize() }

    private func openCurrent() throws {
        let url = directory.appendingPathComponent("runtime.log")
        if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
        let opened = try FileHandle(forWritingTo: url)
        byteCount = Int(try opened.seekToEnd())
        handle = opened
    }

    private func rotate() throws {
        try handle?.close()
        handle = nil
        let manager = FileManager.default
        let oldest = directory.appendingPathComponent("runtime.2.log")
        let previous = directory.appendingPathComponent("runtime.1.log")
        let current = directory.appendingPathComponent("runtime.log")
        if manager.fileExists(atPath: oldest.path) { try manager.removeItem(at: oldest) }
        if manager.fileExists(atPath: previous.path) { try manager.moveItem(at: previous, to: oldest) }
        try manager.moveItem(at: current, to: previous)
        try openCurrent()
    }
}
