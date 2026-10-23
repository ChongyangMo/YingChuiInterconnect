import CoreGraphics
import Foundation

struct DisplayConfigurationSnapshot {
    struct Entry {
        let id: CGDirectDisplayID
        let mirrorSource: CGDirectDisplayID
        let mode: CGDisplayMode
        let origin: CGPoint
    }
    let entries: [Entry]

    static func capture() throws -> Self {
        var count: UInt32 = 0
        try check(CGGetOnlineDisplayList(0, nil, &count), operation: "读取显示器数量")
        guard count > 0 else { throw DisplayConfigurationError.invalidDisplay }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        try check(CGGetOnlineDisplayList(count, &ids, &count), operation: "读取显示器列表")
        var entries: [Entry] = []
        for id in ids.prefix(Int(count)) {
            guard let mode = CGDisplayCopyDisplayMode(id) else { throw DisplayConfigurationError.invalidDisplay }
            entries.append(Entry(id: id, mirrorSource: CGDisplayMirrorsDisplay(id),
                                 mode: mode, origin: CGDisplayBounds(id).origin))
        }
        return Self(entries: entries)
    }

    func restore(using driver: DisplayConfigurationApplying = SystemDisplayConfiguration()) throws {
        try driver.begin()
        var completed = false
        defer { if !completed { driver.cancel() } }
        for entry in entries { try driver.setMirror(entry.id, source: kCGNullDirectDisplay) }
        for entry in entries {
            try driver.setMode(entry.id, mode: entry.mode)
            try driver.setOrigin(entry.id, origin: entry.origin)
        }
        for entry in entries where entry.mirrorSource != kCGNullDirectDisplay {
            try driver.setMirror(entry.id, source: entry.mirrorSource)
        }
        try driver.commit()
        completed = true
    }
}

protocol DisplayConfigurationApplying {
    func begin() throws
    func setMirror(_ id: CGDirectDisplayID, source: CGDirectDisplayID) throws
    func setMode(_ id: CGDirectDisplayID, mode: CGDisplayMode) throws
    func setOrigin(_ id: CGDirectDisplayID, origin: CGPoint) throws
    func commit() throws
    func cancel()
}

private final class SystemDisplayConfiguration: DisplayConfigurationApplying {
    private var configuration: CGDisplayConfigRef?

    func begin() throws {
        try check(CGBeginDisplayConfiguration(&configuration), operation: "开始恢复显示配置")
    }
    func setMirror(_ id: CGDirectDisplayID, source: CGDirectDisplayID) throws {
        guard let configuration else { throw DisplayConfigurationError.invalidDisplay }
        try check(CGConfigureDisplayMirrorOfDisplay(configuration, id, source), operation: "恢复镜像关系")
    }
    func setMode(_ id: CGDirectDisplayID, mode: CGDisplayMode) throws {
        guard let configuration else { throw DisplayConfigurationError.invalidDisplay }
        try check(CGConfigureDisplayWithDisplayMode(configuration, id, mode, nil), operation: "恢复显示模式")
    }
    func setOrigin(_ id: CGDirectDisplayID, origin: CGPoint) throws {
        guard let configuration else { throw DisplayConfigurationError.invalidDisplay }
        try check(CGConfigureDisplayOrigin(configuration, id, Int32(origin.x), Int32(origin.y)), operation: "恢复显示位置")
    }
    func commit() throws {
        guard let configuration else { throw DisplayConfigurationError.invalidDisplay }
        let status = CGCompleteDisplayConfiguration(configuration, .forSession)
        self.configuration = nil
        try check(status, operation: "提交显示配置恢复")
    }
    func cancel() {
        if let configuration { CGCancelDisplayConfiguration(configuration) }
        configuration = nil
    }
}

private func check(_ status: CGError, operation: String) throws {
    guard status == .success else { throw DisplayConfigurationError.system(operation, status.rawValue) }
}

private enum DisplayConfigurationError: LocalizedError {
    case invalidDisplay
    case system(String, Int32)
    var errorDescription: String? {
        switch self {
        case .invalidDisplay: "无法读取完整的原始显示器配置"
        case .system(let operation, let code): "\(operation)失败（\(code)）"
        }
    }
}
