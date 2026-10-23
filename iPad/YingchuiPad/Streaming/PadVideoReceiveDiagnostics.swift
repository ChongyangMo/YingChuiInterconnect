import Foundation
import YingchuiProtocol

struct PadVideoReceiveDiagnostics {
    private var lastPacketUptime: UInt64?
    private var maximumPacketGap: UInt64 = 0
    private var reportedLateFrameID: UInt32?

    mutating func record(_ fragment: VideoFragment, gap: VideoDeliveryGap?,
                         now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> String? {
        if let previous = lastPacketUptime, now >= previous {
            maximumPacketGap = max(maximumPacketGap, now - previous)
        }
        lastPacketUptime = now
        guard let gap, gap.frameID == fragment.frameID, now >= gap.declaredAt,
              reportedLateFrameID != fragment.frameID,
              gap.missingFragments?.contains(fragment.fragmentIndex) != false else { return nil }
        reportedLateFrameID = fragment.frameID
        return "视频缺失分片晚到：帧 \(fragment.frameID)，分片 \(fragment.fragmentIndex + 1)/\(fragment.fragmentCount)，判丢后 \((now - gap.declaredAt) / 1_000_000) 毫秒抵达"
    }

    func describe(_ gap: VideoDeliveryGap) -> String {
        let missing = gap.missingFragments.map { "缺少 \($0.count) 个分片" } ?? "整帧尚未到达"
        return "视频缺口诊断：帧 \(gap.frameID)，\(missing)，本周期最大收包间隔 \(maximumPacketGap / 1_000_000) 毫秒"
    }

    mutating func endInterval() { maximumPacketGap = 0 }
}
