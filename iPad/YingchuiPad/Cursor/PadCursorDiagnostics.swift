import Foundation
import YingchuiProtocol

/// 与视频帧率分开记录，不能把光标刷新算成视频显示帧。
struct PadCursorDiagnostics {
    var localMoves = 0
    var remoteUpdates = 0
    var localSubmit = VideoTimingStatistics()
    var mainWait = VideoTimingStatistics()
    private var start = DispatchTime.now().uptimeNanoseconds

    mutating func report(now: UInt64) -> String? {
        guard now >= start, now - start >= 2_000_000_000, localMoves + remoteUpdates > 0 else { return nil }
        let text = "独立光标分段：窗口 \(String(format: "%.2f", Double(now - start) / 1_000_000_000)) 秒，本地定位 \(localMoves) 次，主机更新 \(remoteUpdates) 次，本地图层提交[\(localSubmit.summary)]，接收至主线程[\(mainWait.summary)]"
        self = Self()
        start = now
        return text
    }
}
