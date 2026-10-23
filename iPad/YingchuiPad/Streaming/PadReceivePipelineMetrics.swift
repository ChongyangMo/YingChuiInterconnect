import Foundation
import YingchuiProtocol

struct PadReceivePipelineMetrics {
    var processing = VideoTimingStatistics()
    var assembly = VideoTimingStatistics()
    var frameAssembly = VideoTimingStatistics()
    var reorderWait = VideoTimingStatistics()
    var packets = 0, bytes = 0, delivered = 0
    var packetInterval = VideoTimingStatistics()
    var systemPacketInterval = VideoTimingStatistics()
    var systemToCallback = VideoTimingStatistics()
    private var lastSystemPacket: UInt64?
    private var firstPackets: [UInt32: UInt64] = [:]
    private var lastPacket: UInt64?
    private var start: UInt64?

    mutating func receiveTiming(_ timing: PadFrameReceiveTiming?) {
        guard let timing, let assembled = timing.assembledAt, let delivered = timing.deliveredAt else { return }
        frameAssembly.record(from: timing.firstCallback, to: assembled)
        reorderWait.record(from: assembled, to: delivered)
    }

    mutating func systemReceive(at timestamp: UInt64, callbackAt: UInt64) {
        guard timestamp > 0, callbackAt >= timestamp else { return }
        systemToCallback.record(from: timestamp, to: callbackAt)
        if let previous = lastSystemPacket { systemPacketInterval.record(from: previous, to: timestamp) }
        lastSystemPacket = timestamp
    }

    mutating func packet(_ fragment: VideoFragment, bytes: Int, now: UInt64) {
        if start == nil { start = now }
        if let previous = lastPacket { packetInterval.record(from: previous, to: now) }
        lastPacket = now
        packets += 1
        self.bytes += bytes
        if firstPackets[fragment.frameID] == nil {
            if firstPackets.count >= 16, let oldest = firstPackets.min(by: { $0.value < $1.value })?.key {
                firstPackets.removeValue(forKey: oldest)
            }
            firstPackets[fragment.frameID] = now
        }
    }

    mutating func frame(_ id: UInt32, now: UInt64) {
        delivered += 1
        if let first = firstPackets.removeValue(forKey: id) { assembly.record(from: first, to: now) }
        firstPackets = firstPackets.filter { Int32(bitPattern: $0.key &- id) > 0 }
    }

    mutating func report(streamID: UUID, now: UInt64) -> String? {
        guard let start, now >= start, now - start >= 2_000_000_000 else { return nil }
        let seconds = Double(now - start) / 1_000_000_000
        let result = "平板接收分段：流 \(streamID)，窗口 \(String(format: "%.2f", seconds)) 秒，收包 \(packets)，交付 \(delivered) 帧，接收 \(String(format: "%.2f", Double(bytes) * 8 / seconds / 1_000_000)) 兆比特每秒；收包间隔[\(packetInterval.summary)]，系统收包间隔[\(systemPacketInterval.summary)]，系统收包到回调[\(systemToCallback.summary)]，单包解密组帧[\(processing.summary)]，首片到交付[\(assembly.summary)]，首片到组装[\(frameAssembly.summary)]，组装后等待[\(reorderWait.summary)]"
        self.start = now
        packets = 0; bytes = 0; delivered = 0
        processing = .init(); assembly = .init(); packetInterval = .init()
        systemPacketInterval = .init(); systemToCallback = .init()
        frameAssembly = .init(); reorderWait = .init()
        return result
    }
}
