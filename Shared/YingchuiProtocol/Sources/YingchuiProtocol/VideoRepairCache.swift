import Foundation

/// 只保存近期已经提交发送的加密分片，串行访问；限制时间、帧数和总字节数。
public struct VideoRepairCache: Sendable {
    private struct Entry: Sendable {
        let id: UInt32
        let packets: [Data]
        let bytes: Int
        let storedAt: UInt64
        var repaired = false
    }
    private var entries: [Entry] = []
    public private(set) var byteCount = 0
    public var frameCount: Int { entries.count }
    private let maximumBytes: Int
    private let maximumFrames: Int
    private let lifetime: UInt64 = 500_000_000

    public init(maximumBytes: Int = 4 * 1024 * 1024, maximumFrames: Int = 30) {
        precondition(maximumBytes > 0 && maximumFrames > 0)
        self.maximumBytes = maximumBytes
        self.maximumFrames = maximumFrames
    }

    public mutating func store(frameID: UInt32, packets: [Data],
                              now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        expire(now: now)
        let bytes = packets.reduce(0) { $0 + $1.count }
        guard !packets.isEmpty, bytes <= maximumBytes else { return }
        while !entries.isEmpty && (entries.count >= maximumFrames || byteCount + bytes > maximumBytes) {
            byteCount -= entries.removeFirst().bytes
        }
        entries.append(Entry(id: frameID, packets: packets, bytes: bytes, storedAt: now))
        byteCount += bytes
    }

    public mutating func take(_ request: VideoRepairRequest,
                              now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> [Data]? {
        expire(now: now)
        guard request.isValid, let index = entries.firstIndex(where: { $0.id == request.frameID }),
              !entries[index].repaired else { return nil }
        let packets = entries[index].packets
        let selected: [Data]
        if let indices = request.fragmentIndices {
            guard indices.allSatisfy({ Int($0) < packets.count }) else { return nil }
            selected = indices.sorted().map { packets[Int($0)] }
        } else {
            guard packets.count <= VideoRepairRequest.maximumPacketCount else { return nil }
            selected = packets
        }
        entries[index].repaired = true
        return selected
    }

    public mutating func reset() { entries.removeAll(keepingCapacity: true); byteCount = 0 }

    private mutating func expire(now: UInt64) {
        while let first = entries.first, now < first.storedAt || now - first.storedAt > lifetime {
            byteCount -= entries.removeFirst().bytes
        }
    }
}
