import CoreGraphics
import Foundation
import YingchuiProtocol

/// 只移动自己的虚拟屏，保持物理屏的模式、主屏和排列不变。
enum MacDisplayLayout {
    static func origin(size: CGSize, physicalBounds: [CGRect], placement: RemoteDisplayPlacement) throws -> CGPoint {
        guard size.width > 0, size.height > 0, !physicalBounds.isEmpty,
              physicalBounds.allSatisfy({ !$0.isEmpty && !$0.isInfinite && !$0.isNull }) else {
            throw LayoutError.invalidBounds
        }
        // 对齐最外侧的真实屏幕，避免不规则多屏排列中的空洞阻断鼠标跨屏。
        switch placement {
        case .left:
            let anchor = physicalBounds.min { $0.minX < $1.minX }!
            return CGPoint(x: anchor.minX - size.width, y: anchor.minY)
        case .right:
            let anchor = physicalBounds.max { $0.maxX < $1.maxX }!
            return CGPoint(x: anchor.maxX, y: anchor.minY)
        case .above:
            let anchor = physicalBounds.min { $0.minY < $1.minY }!
            return CGPoint(x: anchor.minX, y: anchor.minY - size.height)
        case .below:
            let anchor = physicalBounds.max { $0.maxY < $1.maxY }!
            return CGPoint(x: anchor.minX, y: anchor.maxY)
        }
    }

    static func apply(display: CGDirectDisplayID, physical: [CGDirectDisplayID], placement: RemoteDisplayPlacement) throws {
        let point = try origin(size: CGDisplayBounds(display).size,
                               physicalBounds: physical.map { CGDisplayBounds($0) }, placement: placement)
        guard abs(point.x) < Double(Int32.max), abs(point.y) < Double(Int32.max) else { throw LayoutError.invalidBounds }
        if CGDisplayBounds(display).origin == point { return }
        var configuration: CGDisplayConfigRef?
        var status = CGBeginDisplayConfiguration(&configuration)
        guard status == .success, let configuration else { throw LayoutError.configuration(status.rawValue) }
        status = CGConfigureDisplayOrigin(configuration, display, Int32(point.x), Int32(point.y))
        guard status == .success else { CGCancelDisplayConfiguration(configuration); throw LayoutError.configuration(status.rawValue) }
        status = CGCompleteDisplayConfiguration(configuration, .forSession)
        guard status == .success else { throw LayoutError.configuration(status.rawValue) }
    }

    enum LayoutError: LocalizedError {
        case invalidBounds, configuration(Int32), inconsistentState
        var errorDescription: String? {
            switch self {
            case .invalidBounds: "无法读取有效的屏幕排列"
            case .configuration(let code): "应用屏幕排列失败（\(code)）"
            case .inconsistentState: "实际显示器状态与请求不一致"
            }
        }
    }
}
