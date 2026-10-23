import Foundation

struct MacAutomaticUpdatePolicy: Codable, Equatable, Sendable {
    let mode: String
    let check_interval_seconds: Int
    let install_when_idle: Bool

    func validate() throws {
        guard mode == "automatic", check_interval_seconds == 300, install_when_idle else {
            throw MacManagementError.response
        }
    }
}

struct MacAvailableUpdate: Codable, Equatable, Sendable {
    let release_id: String
    let app_version: String
    let app_build: String
    let appcast_url: URL

    func validate() throws {
        guard release_id.count == 64,
              release_id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              MacBuildNumber.isValid(app_build), MacBuildNumber.isValid(app_version),
              appcast_url.absoluteString == MacUpdateSourcePolicy.fixedFeed(releaseID: release_id).absoluteString else {
            throw MacManagementError.response
        }
    }
}

struct MacAutomaticUpdateTarget: Codable, Equatable, Sendable {
    let release: MacAvailableUpdate
    let artifactURL: URL
    let size: UInt64

    func validate(currentBuild: String) throws {
        try release.validate()
        try MacUpdateSourcePolicy.validateArtifact(artifactURL, build: release.app_build, size: size)
        guard MacBuildNumber.isValid(currentBuild),
              artifactURL.deletingLastPathComponent().lastPathComponent == release.release_id,
              !MacBuildNumber.isAtLeast(currentBuild, release.app_build) else {
            throw MacManagementError.response
        }
    }
}

/// 只有实际运行版本达到安装目标才回报完成；下载完毕不能充当安装完成。
@MainActor
final class MacUpdateCompletionStore {
    let url: URL
    private(set) var pending: MacAvailableUpdate?

    init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            pending = try JSONDecoder().decode(MacAvailableUpdate.self, from: Data(contentsOf: url))
            try pending?.validate()
        }
    }

    func state(currentBuild: String) -> MacUpdateState {
        guard let pending else { return .idle }
        return MacBuildNumber.isAtLeast(currentBuild, pending.app_build) ? .installed : .failed
    }

    func prepare(_ release: MacAvailableUpdate) throws {
        try release.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(release).write(to: url, options: .atomic)
        pending = release
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        pending = nil
    }
}
