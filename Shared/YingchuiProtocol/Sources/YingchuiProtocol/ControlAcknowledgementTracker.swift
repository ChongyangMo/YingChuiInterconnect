import Foundation

public struct ControlAcknowledgementMeasurement: Equatable, Sendable {
    public let sentAtUptimeNanoseconds: UInt64
    public let acknowledgedAtUptimeNanoseconds: UInt64

    public var roundTripMilliseconds: Double {
        Double(acknowledgedAtUptimeNanoseconds - sentAtUptimeNanoseconds) / 1_000_000
    }
}

public struct ControlAcknowledgementTracker: Sendable {
    private var pending: [UUID: UInt64] = [:]

    public init() {}

    @discardableResult
    public mutating func begin(
        id: UUID,
        at uptimeNanoseconds: UInt64,
        timeoutNanoseconds: UInt64 = 5_000_000_000
    ) -> Int {
        let expiredCount = expire(
            at: uptimeNanoseconds,
            timeoutNanoseconds: timeoutNanoseconds
        )
        pending[id] = uptimeNanoseconds
        return expiredCount
    }

    @discardableResult
    public mutating func expire(
        at uptimeNanoseconds: UInt64,
        timeoutNanoseconds: UInt64 = 5_000_000_000
    ) -> Int {
        let expired: [UUID] = pending.compactMap { entry in
            let (id, sentAt) = entry
            guard uptimeNanoseconds >= sentAt,
                  uptimeNanoseconds - sentAt > timeoutNanoseconds else { return nil }
            return id
        }
        expired.forEach { pending.removeValue(forKey: $0) }
        return expired.count
    }

    public mutating func acknowledge(id: UUID, at uptimeNanoseconds: UInt64) -> Double? {
        acknowledgeMeasurement(id: id, at: uptimeNanoseconds)?.roundTripMilliseconds
    }

    public mutating func acknowledgeMeasurement(
        id: UUID,
        at uptimeNanoseconds: UInt64
    ) -> ControlAcknowledgementMeasurement? {
        guard let sentAt = pending.removeValue(forKey: id),
              uptimeNanoseconds >= sentAt else { return nil }
        return ControlAcknowledgementMeasurement(
            sentAtUptimeNanoseconds: sentAt,
            acknowledgedAtUptimeNanoseconds: uptimeNanoseconds
        )
    }

    @discardableResult
    public mutating func cancel(id: UUID) -> Bool {
        pending.removeValue(forKey: id) != nil
    }

    public mutating func reset() {
        pending.removeAll(keepingCapacity: true)
    }
}
