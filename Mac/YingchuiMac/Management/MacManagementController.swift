import Combine
import Foundation
import YingchuiProtocol

@MainActor
final class MacManagementController: ObservableObject {
    @Published private(set) var lastError: String?
    @Published private(set) var lastHeartbeat: Date?
    private var observation: AnyCancellable?
    private weak var account: AccountModel?
    private weak var host: MacHostModel?
    private weak var updates: MacUpdateController?
    private var service: (any MacManagementService)?
    private var installationID: String?
    private var activeUserID: String?
    private var generation = UUID()
    private var started = false
    private let pump = MacHeartbeatPump()
    private let log = DiagnosticEventLog(subsystem: "com.yingchui.interconnect.mac", category: "后台管理")

    func start(account: AccountModel, host: MacHostModel, updates: MacUpdateController) {
        guard !started else { return }
        started = true
        self.account = account
        self.host = host
        self.updates = updates
        do {
            let configuration = try MacManagementConfiguration.load()
            service = try MacManagementAPI(configuration: configuration)
            // 公开更新与账号、安装身份存储解耦。
            try updates.start(configuration: configuration, isIdle: { [weak host, weak account] in
                guard let host, let account else { return false }
                return MacUpdateIdlePolicy.snapshot(host: host, account: account).canInstall
            }, reserveInstallation: { [weak host] in
                guard let host else { return false }
                return await host.reserveAutomaticUpdate()
            }, releaseInstallation: { [weak host] in host?.automaticUpdateBarrier.set(false) })
            installationID = try MacInstallationIdentity.load(at: MacInstallationIdentity.applicationURL())
            updates.onStateChange = { [weak self] in self?.pump.request() }
            observation = account.sessions.$user.map { $0?.id }.removeDuplicates().sink { [weak self] id in
                Task { @MainActor [weak self] in self?.restart(for: id) }
            }
        } catch { report(error) }
    }

    private func restart(for id: String?) {
        guard account?.user?.id == id else { return }
        pump.stop()
        generation = UUID()
        activeUserID = id
        lastHeartbeat = nil
        guard id != nil else { lastError = nil; return }
        let expected = generation
        pump.start(operation: { [weak self] in try await self?.tick(expected: expected) },
                   onError: { [weak self] in self?.report($0) })
    }

    private func tick(expected: UUID) async throws {
        guard let service, let updates, let account, let userID = activeUserID,
              account.user?.id == userID else { throw CancellationError() }
        let status = try await service.status()
        try check(expected)
        guard status.management_available else { throw MacManagementError.unavailable }
        try status.validateAutomaticUpdates()
        let payload = try heartbeatPayload()
        let sessionGeneration = account.sessions.generation
        let receipt = try await MacHeartbeatOperation.send(payload, service: service, sessions: account.sessions)
        try check(expected)
        try account.sessions.check(sessionGeneration)
        guard let policy = receipt.update_policy else { throw MacManagementError.automaticUnavailable }
        try policy.validate()
        if payload.update_state == .installed { try updates.acknowledgeInstalledBuild(payload.app_build) }
        lastHeartbeat = Date()
        lastError = nil
        log.recordPeriodic("后台心跳已确认，服务\(payload.service_running ? "运行中" : "已停止")，回传\(payload.streaming ? "进行中" : "未开始")，更新状态 \(payload.update_state.logName)",
            key: "后台心跳", intervalNanoseconds: 900_000_000_000)
    }

    private func check(_ expected: UUID) throws {
        try Task.checkCancellation()
        guard generation == expected, account?.user?.id == activeUserID else { throw CancellationError() }
    }

    private func heartbeatPayload() throws -> MacHeartbeat {
        guard let installationID, let host, let updates,
              let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              MacBuildNumber.isValid(version), MacBuildNumber.isValid(build) else { throw MacManagementError.configuration }
        return MacHeartbeat(installation_id: installationID, app_version: version, app_build: build,
            os_version: MacUpdateSourcePolicy.osVersion, architecture: MacUpdateSourcePolicy.architecture,
            service_running: host.isRunning, streaming: host.isStreaming, update_state: updates.state,
            channel: .unified, automatic_updates: updates.automaticUpdatesEnabled)
    }

    private func report(_ error: Error) {
        lastError = error.localizedDescription
        log.recordPeriodic("后台连接失败：\(error.localizedDescription)", key: "后台连接错误", intervalNanoseconds: 300_000_000_000)
    }
}
