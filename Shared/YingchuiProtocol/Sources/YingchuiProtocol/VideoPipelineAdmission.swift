import Foundation

/// 在编码之前预约容量；票据让旧回调无法释放新会话的槽位。
public struct VideoPipelineAdmission: Sendable {
    private var tickets: Set<UUID> = []
    private let maximumEncodes: Int
    private let maximumQueuedPackets: Int
    private let maximumQueueAge: UInt64
    public var pendingEncodes: Int { tickets.count }

    public init(maximumEncodes: Int = 1, maximumQueuedPackets: Int = 128,
                maximumQueueAgeNanoseconds: UInt64 = 32_000_000) {
        precondition(maximumEncodes > 0 && maximumQueuedPackets > 0)
        self.maximumEncodes = maximumEncodes
        self.maximumQueuedPackets = maximumQueuedPackets
        self.maximumQueueAge = maximumQueueAgeNanoseconds
    }

    public mutating func admit(queuedPackets: Int, oldestQueuedAgeNanoseconds: UInt64) -> UUID? {
        guard tickets.count < maximumEncodes, queuedPackets < maximumQueuedPackets,
              oldestQueuedAgeNanoseconds < maximumQueueAge else { return nil }
        let ticket = UUID()
        tickets.insert(ticket)
        return ticket
    }

    @discardableResult
    public mutating func complete(_ ticket: UUID) -> Bool { tickets.remove(ticket) != nil }
    public mutating func reset() { tickets.removeAll(keepingCapacity: true) }
}
