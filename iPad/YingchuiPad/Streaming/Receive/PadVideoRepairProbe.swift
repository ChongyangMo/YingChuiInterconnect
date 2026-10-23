#if DEBUG
import Foundation
import YingchuiProtocol

/// 显式调试参数下丢弃一片真实视频数据，只验证补发恢复，不用于日常性能结论。
struct PadVideoRepairProbe {
    private static let enabled = ProcessInfo.processInfo.arguments.contains("--video-repair-probe")
    private var consumed = false
    mutating func shouldDiscard(_ fragment: VideoFragment) -> Bool {
        guard Self.enabled, !consumed,
              !fragment.isKeyFrame, fragment.frameID >= 120, fragment.fragmentCount > 1,
              fragment.fragmentIndex + 1 == fragment.fragmentCount else { return false }
        consumed = true
        return true
    }
}
#endif
