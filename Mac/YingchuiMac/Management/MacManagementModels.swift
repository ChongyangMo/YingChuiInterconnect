import Foundation

enum MacUpdateState: String, Codable, Sendable {
    case idle, checking, available, downloading, downloaded, deferred, installing, installed, failed
    var logName: String {
        switch self {
        case .idle: "空闲"
        case .checking: "检查中"
        case .available: "有可用更新"
        case .downloading: "下载中"
        case .downloaded: "已下载"
        case .deferred: "已延期"
        case .installing: "安装中"
        case .installed: "已安装"
        case .failed: "失败"
        }
    }
}

enum MacReleaseChannel: String, Codable, Sendable { case unified, stable, beta }

struct MacManagementConfiguration: Decodable, Sendable {
    let baseURL: URL
    let contractVersion: String
    let channel: MacReleaseChannel
    let useSystemProxy: Bool
    var automatic_updates: Bool = true

    static func load(bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "MacManagementConfiguration", withExtension: "json") else {
            throw MacManagementError.configuration
        }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try value.validate()
        return value
    }

    func validate() throws {
        guard baseURL.scheme == "https", baseURL.host == "chongyang.asia", baseURL.port == nil,
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil,
              ["", "/"].contains(baseURL.path), contractVersion == "mac-management-v1" else {
            throw MacManagementError.configuration
        }
    }

    var feedURL: URL {
        baseURL.appendingPathComponent("updates/yingchui/mac/\(MacUpdateSourcePolicy.architecture)/\(MacUpdateSourcePolicy.osVersion)/appcast.xml")
    }
}

struct MacManagementStatus: Decodable, Sendable {
    let contract_version: String
    let management_available: Bool
    let updates_available: Bool
    var push_available: Bool? = nil
    var update_policy: MacAutomaticUpdatePolicy? = nil

    func validateAutomaticUpdates() throws {
        guard updates_available else { throw MacManagementError.unavailable }
        guard push_available == false, let update_policy else { throw MacManagementError.automaticUnavailable }
        try update_policy.validate()
    }
}

struct MacHeartbeat: Encodable, Sendable {
    let installation_id: String
    let app_version: String
    let app_build: String
    let os_version: String
    let architecture: String
    let service_running: Bool
    let streaming: Bool
    let update_state: MacUpdateState
    let channel: MacReleaseChannel
    var automatic_updates: Bool = false
}

struct MacHeartbeatReceipt: Decodable, Sendable {
    let contract_version: String
    let next_heartbeat_seconds: Int
    let update_available: Bool
    let latest_build: String?
    var available_update: MacAvailableUpdate? = nil
    var update_policy: MacAutomaticUpdatePolicy? = nil

    func validate() throws {
        guard contract_version == "mac-management-v1", (60...3600).contains(next_heartbeat_seconds),
              (!update_available || latest_build != nil),
              latest_build.map(MacBuildNumber.isValid) != false else { throw MacManagementError.response }
        try update_policy?.validate()
        try available_update?.validate()
        if update_policy != nil {
            guard next_heartbeat_seconds == 300,
                  update_available == (available_update != nil),
                  available_update == nil || latest_build == available_update?.app_build else {
                throw MacManagementError.response
            }
        }
    }
}

enum MacBuildNumber {
    static func isAtLeast(_ current: String, _ target: String) -> Bool {
        guard isValid(current), isValid(target) else { return false }
        let left = current.split(separator: ".").compactMap { UInt64($0) }
        let right = target.split(separator: ".").compactMap { UInt64($0) }
        for index in 0..<3 {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return true
    }

    static func isValid(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return (1...3).contains(parts.count) && parts.allSatisfy {
            (1...18).contains($0.utf8.count) && ($0.count == 1 || $0.first != "0") &&
            $0.utf8.allSatisfy { (48...57).contains($0) }
        }
    }
}

enum MacManagementError: LocalizedError, Equatable {
    case configuration, identity, response, unavailable, automaticUnavailable, unauthorized, http(Int), streaming, updateCancelled, invalidUpdateJob, releaseWithdrawn
    var errorDescription: String? {
        switch self {
        case .configuration: "后台管理配置无效。"
        case .identity: "安装标识读取失败，请检查应用数据。"
        case .response: "后台返回的数据不符合约定。"
        case .unavailable: "后台管理或更新服务尚未开放。"
        case .automaticUnavailable: "自动更新服务尚未开放，请先发布配套后台。"
        case .unauthorized: "后台会话已失效，请重新登录。"
        case .http(let code): "后台请求失败（\(code)）。"
        case .streaming: "当前操作结束后将自动安装更新。"
        case .updateCancelled: "本次更新任务已停止。"
        case .invalidUpdateJob: "更新任务已失效，正在重新同步。"
        case .releaseWithdrawn: "这个更新版本已撤回。"
        }
    }
}
