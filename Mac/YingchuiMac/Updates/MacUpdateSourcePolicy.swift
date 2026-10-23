import Foundation

enum MacUpdateSourcePolicy {
    static var osVersion: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }

    static func fixedFeed(releaseID: String) -> URL {
        URL(string: "https://chongyang.asia/updates/yingchui/mac/\(architecture)/releases/\(releaseID)/appcast.xml")!
    }

    static var architecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
#error("不支持的 Mac 架构")
#endif
    }

    static func validateArtifact(_ url: URL?, build: String, size: UInt64) throws {
        guard let url, url.scheme == "https", url.host == "chongyang.asia", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              ["zip", "dmg"].contains(url.pathExtension.lowercased()),
              MacBuildNumber.isValid(build), size > 0, size <= 256 * 1024 * 1024 else {
            throw MacManagementError.response
        }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 7, parts[0].isEmpty, parts[1...4].joined(separator: "/") == "updates/yingchui/mac/artifacts",
              parts[5].count == 64, parts[5].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              !parts[6].isEmpty else { throw MacManagementError.response }
    }
}
