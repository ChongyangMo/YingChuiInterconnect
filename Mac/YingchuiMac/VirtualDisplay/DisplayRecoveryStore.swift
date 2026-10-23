import CoreGraphics
import Foundation

struct DisplayRecoveryRecord: Codable, Equatable {
    struct Entry: Codable, Equatable {
        let displayUUID: String
        let mirrorUUID: String?
        let width: Int
        let height: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let refreshRate: Double
        let x: Double
        let y: Double
    }
    let entries: [Entry]

    init(snapshot: DisplayConfigurationSnapshot) throws {
        entries = try snapshot.entries.map { entry in
            Entry(displayUUID: try Self.uuid(entry.id),
                  mirrorUUID: entry.mirrorSource == kCGNullDirectDisplay ? nil : try Self.uuid(entry.mirrorSource),
                  width: entry.mode.width, height: entry.mode.height,
                  pixelWidth: entry.mode.pixelWidth, pixelHeight: entry.mode.pixelHeight,
                  refreshRate: entry.mode.refreshRate, x: entry.origin.x, y: entry.origin.y)
        }
    }

    static func uuid(_ display: CGDirectDisplayID) throws -> String {
        guard CGDisplayIsOnline(display) != 0 else { throw DisplayRecoveryError.unavailable }
        // 使用公开硬件标识；无序列号屏幕还须匹配连接单元，无法唯一匹配时拒绝恢复。
        return "\(CGDisplayVendorNumber(display))-\(CGDisplayModelNumber(display))-\(CGDisplaySerialNumber(display))-\(CGDisplayUnitNumber(display))"
    }

    func resolve() throws -> DisplayConfigurationSnapshot {
        _ = try requiredDisplayUUIDs()
        let current = try MacDisplayRouting.onlineDisplays()
        var identifiers: [String: CGDirectDisplayID] = [:]
        for id in current {
            let key = Self.canonicalIdentifier(try Self.uuid(id))
            guard identifiers[key] == nil else { throw DisplayRecoveryError.unavailable }
            identifiers[key] = id
        }
        guard !entries.isEmpty else { throw DisplayRecoveryError.invalidRecord }
        let restored: [DisplayConfigurationSnapshot.Entry] = try entries.map { entry in
            guard let id = identifiers[Self.canonicalIdentifier(entry.displayUUID)], entry.x.isFinite, entry.y.isFinite,
                  abs(entry.x) <= Double(Int32.max), abs(entry.y) <= Double(Int32.max),
                  let modes = CGDisplayCopyAllDisplayModes(id,
                    [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode],
                  let mode = modes.first(where: {
                      $0.width == entry.width && $0.height == entry.height &&
                      $0.pixelWidth == entry.pixelWidth && $0.pixelHeight == entry.pixelHeight &&
                      abs($0.refreshRate - entry.refreshRate) < 0.5
                  }) else { throw DisplayRecoveryError.unavailable }
            let mirror: CGDirectDisplayID
            if let uuid = entry.mirrorUUID {
                guard let source = identifiers[Self.canonicalIdentifier(uuid)] else { throw DisplayRecoveryError.unavailable }
                mirror = source
            } else { mirror = kCGNullDirectDisplay }
            return DisplayConfigurationSnapshot.Entry(id: id, mirrorSource: mirror, mode: mode,
                                                       origin: CGPoint(x: entry.x, y: entry.y))
        }
        return DisplayConfigurationSnapshot(entries: restored)
    }
}

final class DisplayRecoveryStore {
    let url: URL
    init(url: URL = URL.applicationSupportDirectory
        .appending(path: "com.yingchui.interconnect.mac/display-recovery.json")) { self.url = url }
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    func save(_ record: DisplayRecoveryRecord) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
    }
    func load() throws -> DisplayRecoveryRecord {
        guard exists else { throw DisplayRecoveryError.missingRecord }
        return try JSONDecoder().decode(DisplayRecoveryRecord.self, from: Data(contentsOf: url))
    }
    func clear() throws {
        guard exists else { throw DisplayRecoveryError.missingRecord }
        try FileManager.default.removeItem(at: url)
    }
}

enum DisplayRecoveryError: LocalizedError {
    case unavailable, invalidRecord, missingRecord, pendingRecovery
    var errorDescription: String? {
        switch self {
        case .unavailable: "原显示器或显示模式不可用，请连接原显示器后重试恢复"
        case .invalidRecord: "保存的显示配置无效"
        case .missingRecord: "没有待恢复的显示配置"
        case .pendingRecovery: "检测到上次未恢复的显示配置，请先恢复显示器"
        }
    }
}
