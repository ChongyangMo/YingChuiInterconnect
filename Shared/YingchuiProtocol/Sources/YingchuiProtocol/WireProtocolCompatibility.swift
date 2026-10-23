import Foundation

public enum WireProtocolCompatibility {
    // 9 以前缺少现有显示与光标契约，不降低安全或业务协议要求。
    public static let minimumSupportedVersion = 9

    public static func negotiatedVersion(peerVersion: Int, peerMinimum: Int?) -> Int? {
        let floor = peerMinimum ?? peerVersion
        guard peerVersion > 0, floor > 0, floor <= peerVersion,
              peerVersion >= minimumSupportedVersion,
              floor <= YingchuiService.protocolVersion else { return nil }
        return min(peerVersion, YingchuiService.protocolVersion)
    }
}
