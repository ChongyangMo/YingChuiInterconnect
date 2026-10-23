import Foundation

public struct VideoFrameReassembler: Sendable {
    private struct Assembly: Sendable {
        let streamID: UUID
        let frameID: UInt32
        let presentationTimeMicroseconds: UInt64
        let isKeyFrame: Bool
        let firstReceivedUptimeNanoseconds: UInt64
        var lastUpdatedUptimeNanoseconds: UInt64
        var fragments: [Data?]
        var receivedCount: Int
        var receivedBytes: Int
    }

    private var assemblies: [UInt32: Assembly] = [:]
    private let maximumPendingFrames: Int
    private var lastCompletedFrameID: UInt32?
    private let defersDelivery: Bool
    private var completedFrameIDs: Set<UInt32> = []

    public init(maximumPendingFrames: Int = 8, defersDelivery: Bool = false) {
        self.maximumPendingFrames = max(1, maximumPendingFrames)
        self.defersDelivery = defersDelivery
    }

    public mutating func append(
        _ fragment: VideoFragment,
        receivedAtUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> CompletedVideoFrame? {
        guard fragment.fragmentCount > 0,
              Int(fragment.fragmentCount) <= VideoDatagramCodec.maximumFragmentsPerFrame,
              fragment.fragmentIndex < fragment.fragmentCount,
              fragment.payload.count <= VideoDatagramCodec.maximumPayloadSize else {
            return nil
        }
        if let lastCompletedFrameID,
           Int32(bitPattern: fragment.frameID &- lastCompletedFrameID) <= 0 {
            return nil
        }
        guard !completedFrameIDs.contains(fragment.frameID) else { return nil }
        if assemblies[fragment.frameID] == nil {
            if assemblies.count >= maximumPendingFrames,
               let oldest = assemblies.min(by: {
                   $0.value.lastUpdatedUptimeNanoseconds < $1.value.lastUpdatedUptimeNanoseconds
               })?.key {
                assemblies.removeValue(forKey: oldest)
            }
            assemblies[fragment.frameID] = Assembly(
                streamID: fragment.streamID,
                frameID: fragment.frameID,
                presentationTimeMicroseconds: fragment.presentationTimeMicroseconds,
                isKeyFrame: fragment.isKeyFrame,
                firstReceivedUptimeNanoseconds: receivedAtUptimeNanoseconds,
                lastUpdatedUptimeNanoseconds: receivedAtUptimeNanoseconds,
                fragments: Array(repeating: nil, count: Int(fragment.fragmentCount)),
                receivedCount: 0,
                receivedBytes: 0
            )
        }

        // 先取出再修改，避免字典和局部变量同时持有分片数组，触发每包整数组复制。
        guard var assembly = assemblies.removeValue(forKey: fragment.frameID),
              assembly.streamID == fragment.streamID,
              assembly.presentationTimeMicroseconds == fragment.presentationTimeMicroseconds,
              assembly.isKeyFrame == fragment.isKeyFrame,
              assembly.fragments.count == Int(fragment.fragmentCount) else {
            assemblies.removeValue(forKey: fragment.frameID)
            return nil
        }

        let index = Int(fragment.fragmentIndex)
        if assembly.fragments[index] == nil {
            guard assembly.receivedBytes + fragment.payload.count <= VideoDatagramCodec.maximumAccessUnitSize else {
                assemblies.removeValue(forKey: fragment.frameID)
                return nil
            }
            assembly.fragments[index] = fragment.payload
            assembly.receivedCount += 1
            assembly.receivedBytes += fragment.payload.count
        }
        assembly.lastUpdatedUptimeNanoseconds = receivedAtUptimeNanoseconds
        guard assembly.receivedCount == assembly.fragments.count else {
            assemblies[fragment.frameID] = assembly
            return nil
        }
        var accessUnit = Data(capacity: assembly.receivedBytes)
        for payload in assembly.fragments {
            guard let payload else { return nil }
            accessUnit.append(payload)
        }
        assemblies.removeValue(forKey: fragment.frameID)
        if defersDelivery {
            completedFrameIDs.insert(fragment.frameID)
            if completedFrameIDs.count > maximumPendingFrames + 1,
               let oldest = completedFrameIDs.min(by: { Int32(bitPattern: $0 &- $1) < 0 }) {
                completedFrameIDs.remove(oldest)
            }
        } else {
            discardThrough(frameID: fragment.frameID)
        }
        return CompletedVideoFrame(
            streamID: assembly.streamID,
            frameID: assembly.frameID,
            presentationTimeMicroseconds: assembly.presentationTimeMicroseconds,
            isKeyFrame: assembly.isKeyFrame,
            accessUnit: accessUnit
        )
    }

    public mutating func reset() {
        assemblies.removeAll(keepingCapacity: true)
        lastCompletedFrameID = nil
        completedFrameIDs.removeAll(keepingCapacity: true)
    }

    public func missingFragments(for frameID: UInt32) -> [UInt16]? {
        guard let assembly = assemblies[frameID] else { return nil }
        return assembly.fragments.indices.compactMap {
            assembly.fragments[$0] == nil ? UInt16($0) : nil
        }
    }

    public func firstFragmentOfFrameNewer(than frameID: UInt32) -> UInt64? {
        assemblies.values.filter { Int32(bitPattern: $0.frameID &- frameID) > 0 }
            .map(\.firstReceivedUptimeNanoseconds).min()
    }

    /// 只有交付后才推进水位，允许先完成的新帧等待尚未收齐的前一帧。
    public mutating func discardThrough(frameID: UInt32) {
        if let previous = lastCompletedFrameID, Int32(bitPattern: frameID &- previous) <= 0 { return }
        lastCompletedFrameID = frameID
        assemblies = assemblies.filter { Int32(bitPattern: $0.key &- frameID) > 0 }
        completedFrameIDs = completedFrameIDs.filter { Int32(bitPattern: $0 &- frameID) > 0 }
    }

    @discardableResult
    public mutating func discardIncompleteFrames(olderThanUptimeNanoseconds cutoff: UInt64) -> Int {
        let expiredFrameIDs = assemblies.compactMap { frameID, assembly in
            assembly.lastUpdatedUptimeNanoseconds < cutoff ? frameID : nil
        }
        for frameID in expiredFrameIDs {
            assemblies.removeValue(forKey: frameID)
        }
        return expiredFrameIDs.count
    }
}
