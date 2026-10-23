import CoreGraphics
import Foundation

enum MacDisplayRouting {
    static func isSystemVirtualDisplay(_ display: CGDirectDisplayID) -> Bool {
        isSystemVirtualDisplay(vendor: CGDisplayVendorNumber(display), model: CGDisplayModelNumber(display))
    }

    static func isSystemVirtualDisplay(vendor: UInt32, model: UInt32) -> Bool {
        // macOS 无屏时创建的占位桌面：'unkn' / 'virt'。不能按名称是否为空判断硬件。
        vendor == 0x756e6b6e && model == 0x76697274
    }

    static func isMacStreamDisplay(_ display: CGDirectDisplayID) -> Bool {
        isMacStreamDisplay(vendor: CGDisplayVendorNumber(display), model: CGDisplayModelNumber(display))
    }

    /// MacStream（Windows 远程控制 Mac）连接期间创建的虚拟屏，它会让其他显示器镜像自己。
    static func isMacStreamDisplay(vendor: UInt32, model: UInt32) -> Bool {
        vendor == 0x4D53 && model == 0x0001
    }

    /// 不能作为镜像对象或拓扑依据的显示器：系统占位桌面与其他程序的虚拟屏。
    static func isNonPhysicalDisplay(_ display: CGDirectDisplayID) -> Bool {
        isSystemVirtualDisplay(display) || isMacStreamDisplay(display)
    }

    /// 两个程序同时改镜像会互相覆盖并写错恢复记录，MacStream 占用期间明确拒绝。
    static func requireDisplaysNotOccupied() throws {
        if let display = try onlineDisplays().first(where: isMacStreamDisplay) {
            throw RoutingError.occupiedByMacStream(display)
        }
    }

    static func onlineDisplays() throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        var status = CGGetOnlineDisplayList(0, nil, &count)
        guard status == .success else { throw RoutingError.enumeration(status.rawValue) }
        // 零块在线显示器是无屏模式，不伪造物理屏或分辨率。
        guard count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        status = CGGetOnlineDisplayList(count, &displays, &count)
        guard status == .success else { throw RoutingError.enumeration(status.rawValue) }
        return Array(displays.prefix(Int(count)))
    }

    /// nil 明确表示独立虚拟桌面；仍有显示器但选择无效时直接报错。
    static func mirrorTarget(selected: CGDirectDisplayID?, online: [CGDirectDisplayID],
                             ownedVirtualDisplay: CGDirectDisplayID?,
                             systemVirtualDisplays: Set<CGDirectDisplayID> = []) throws -> CGDirectDisplayID? {
        // 正在使用的独立桌面不因插入另一块屏而自动变成镜像。
        if let ownedVirtualDisplay, online.contains(ownedVirtualDisplay), selected == nil { return nil }
        let displays = online.filter {
            $0 != kCGNullDirectDisplay && $0 != ownedVirtualDisplay && !systemVirtualDisplays.contains($0)
        }
        guard !displays.isEmpty else { return nil }
        guard let selected, displays.contains(selected) else { throw RoutingError.selectionUnavailable }
        return selected
    }

    private enum RoutingError: LocalizedError {
        case enumeration(Int32), selectionUnavailable, occupiedByMacStream(CGDirectDisplayID)
        var errorDescription: String? {
            switch self {
            case .enumeration(let code): "读取在线显示器失败（\(code)）"
            case .selectionUnavailable: "所选显示器不可用，请刷新并重新选择"
            case .occupiedByMacStream(let display): "Windows 端 MacStream 正在使用显示器（虚拟屏 \(display)），请断开后约 10 秒再试"
            }
        }
    }
}
