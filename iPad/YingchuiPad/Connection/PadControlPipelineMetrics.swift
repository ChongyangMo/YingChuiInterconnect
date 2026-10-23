import Foundation
import YingchuiProtocol

/// 只在控制网络队列累计，输出汇总，不逐条打印鼠标事件。
struct PadControlPipelineMetrics {
    var queueWait = VideoTimingStatistics()
    var mergeWait = VideoTimingStatistics()
    var acknowledgement = VideoTimingStatistics()
    var firstPendingMove: UInt64?
    private var windowStart = DispatchTime.now().uptimeNanoseconds

    mutating func reportIfNeeded(to log: DiagnosticEventLog, now: UInt64) {
        guard now >= windowStart, now - windowStart >= 2_000_000_000 else { return }
        log.record("输入链路分段：移动入队[\(queueWait.summary)]，移动合并等待[\(mergeWait.summary)]，控制发送至执行回执[\(acknowledgement.summary)]")
        queueWait = .init()
        mergeWait = .init()
        acknowledgement = .init()
        windowStart = now
    }
}
