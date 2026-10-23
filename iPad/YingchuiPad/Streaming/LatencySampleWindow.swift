import Foundation

struct LatencySampleWindow: Sendable {
    private(set) var values: [Double] = []
    let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0, "延迟样本容量必须大于零")
        self.capacity = capacity
    }

    mutating func append(_ value: Double) {
        guard value.isFinite, value >= 0 else { return }
        values.append(value)
        if values.count > capacity {
            values.removeFirst(values.count - capacity)
        }
    }

    func percentile(_ rank: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let boundedRank = min(max(rank, 0), 1)
        let ordered = values.sorted()
        let position = Int((Double(ordered.count - 1) * boundedRank).rounded(.up))
        return ordered[position]
    }

    mutating func reset() {
        values.removeAll(keepingCapacity: true)
    }
}
