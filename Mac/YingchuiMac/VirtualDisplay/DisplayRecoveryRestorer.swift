import CoreGraphics
import Foundation

extension DisplayRecoveryRecord {
    // 保持旧记录兼容：有序列号时用硬件身份匹配，连接单元会在重插后变化。
    static func canonicalIdentifier(_ identifier: String) -> String {
        let parts = identifier.split(separator: "-", omittingEmptySubsequences: false)
        if parts.count == 4, let serial = UInt32(parts[2]), serial != 0 {
            return parts.prefix(3).joined(separator: "-")
        }
        return identifier
    }

    // 缺少硬件是等待重插的状态；记录损坏、模式不匹配仍然必须报错。
    func requiredDisplayUUIDs() throws -> Set<String> {
        let identifiers = Set(entries.map { Self.canonicalIdentifier($0.displayUUID) })
        guard !entries.isEmpty, identifiers.count == entries.count else {
            throw DisplayRecoveryError.invalidRecord
        }
        for entry in entries {
            guard !entry.displayUUID.isEmpty,
                  entry.width > 0, entry.height > 0, entry.pixelWidth > 0, entry.pixelHeight > 0,
                  entry.refreshRate.isFinite, entry.refreshRate >= 0,
                  entry.x.isFinite, entry.y.isFinite,
                  abs(entry.x) <= Double(Int32.max), abs(entry.y) <= Double(Int32.max),
                  entry.mirrorUUID == nil || (entry.mirrorUUID != entry.displayUUID && identifiers.contains(Self.canonicalIdentifier(entry.mirrorUUID!))) else {
                throw DisplayRecoveryError.invalidRecord
            }
        }
        return identifiers
    }
}

struct DisplayRecoveryRestorer {
    enum Result: Equatable {
        case nothingToRestore, restored, waitingForHardware
    }
    let store: DisplayRecoveryStore
    var onlineIdentifiers: () throws -> Set<String> = {
        let identifiers = try MacDisplayRouting.onlineDisplays().map { DisplayRecoveryRecord.canonicalIdentifier(try DisplayRecoveryRecord.uuid($0)) }
        guard Set(identifiers).count == identifiers.count else { throw DisplayRecoveryError.unavailable }
        return Set(identifiers)
    }
    var apply: (DisplayRecoveryRecord) throws -> Void = { try $0.resolve().restore() }

    func restoreAvailable() throws -> Result {
        guard store.exists else { return .nothingToRestore }
        let record = try store.load()
        let required = try record.requiredDisplayUUIDs()
        guard required.isSubset(of: try onlineIdentifiers()) else { return .waitingForHardware }
        try apply(record)
        // 只有完整恢复成功才清除记录，任何真实错误均保留原始数据。
        try store.clear()
        return .restored
    }
}
