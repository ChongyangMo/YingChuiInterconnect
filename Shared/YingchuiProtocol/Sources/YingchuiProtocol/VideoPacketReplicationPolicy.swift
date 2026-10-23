import Foundation

public enum VideoPacketReplicationPolicy {
    public static func copiesPerFragment(
        isKeyFrame: Bool,
        fragmentCount: Int,
        maximumOutstandingDatagrams: Int = 1_024
    ) -> Int {
        guard isKeyFrame,
              fragmentCount > 0,
              fragmentCount <= maximumOutstandingDatagrams / 2 else { return 1 }
        return 2
    }
}
