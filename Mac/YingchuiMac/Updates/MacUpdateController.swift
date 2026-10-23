import AppKit
import Combine
import Sparkle
import YingchuiProtocol

@MainActor
final class MacUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    @Published var state: MacUpdateState = .idle {
        didSet { if oldValue != state { onStateChange?() } }
    }
    @Published var message: String?
    @Published var canCheck = false
    @Published private(set) var automaticUpdatesEnabled = false
    var onStateChange: (() -> Void)?
    var sparkle: SPUUpdater?
    var userDriver: MacUpdateUserDriver?
    var configuration: MacManagementConfiguration?
    var target: MacAutomaticUpdateTarget?
    var sessionID: UUID?
    var manualCheck = false
    @Published var installationCommitted = false
    var isIdle: () -> Bool = { false }
    var reserveInstallation: () async -> Bool = { true }
    var releaseInstallation: () -> Void = {}
    let installation = MacIdleInstallationCoordinator()
    let scheduler = MacAutomaticUpdateScheduler()
    let log = DiagnosticEventLog(subsystem: "com.yingchui.interconnect.mac", category: "应用更新")
    let defaults: UserDefaults
    var completion: MacUpdateCompletionStore?
    var verifier: MacPublishedReleaseVerifier?
    var service: (any MacManagementService)?
    var observation: AnyCancellable?
    var checkTask: Task<Void, Never>?
    var probing = false
    var stopping = false
    var isTerminating = false
    var currentBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }
    var sessionIsCurrent: Bool { sessionID != nil && !stopping }
    var hasDeferredInstallation: Bool { installation.hasPendingInstallation }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    func start(configuration: MacManagementConfiguration, isIdle: @escaping () -> Bool,
               reserveInstallation: @escaping () async -> Bool = { true },
               releaseInstallation: @escaping () -> Void = {}) throws {
        guard sparkle == nil else { return }
        try configuration.validate()
        guard configuration.automatic_updates, MacBuildNumber.isValid(currentBuild) else { throw MacManagementError.configuration }
        self.configuration = configuration
        self.isIdle = isIdle
        self.reserveInstallation = reserveInstallation
        self.releaseInstallation = releaseInstallation
        service = try MacManagementAPI(configuration: configuration)
        verifier = MacPublishedReleaseVerifier(transport: AccountURLSessionTransport(useSystemProxy: configuration.useSystemProxy))
        let identityURL = try MacInstallationIdentity.applicationURL()
        completion = try MacUpdateCompletionStore(url: identityURL.deletingLastPathComponent().appendingPathComponent("automatic-installation.json"))
        state = completion!.state(currentBuild: currentBuild)
        if state == .failed { message = "上次更新未完成，将重新检查可用版本。" }
        // 此前的推送偏好不再参与公开更新；历史文件保留，不作为新流程的输入。
        for key in ["mac.update.targetedMode", "mac.update.pendingBuild", "SUSkippedVersion",
                    "SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUScheduledCheckInterval"] {
            defaults.removeObject(forKey: key)
        }
        let driver = MacUpdateUserDriver(hostBundle: .main, delegate: self)
        driver.allowsSession = { [weak self] in self?.sessionIsCurrent == true }
        driver.verifyDownload = { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.verifyCurrentRelease()
        }
        driver.prepareInstallation = { [weak self] install, cancel in
            guard let self else { cancel(); return }
            self.deferInstallation(install: install, cancel: cancel)
        }
        driver.onFailure = { [weak self] in self?.fail($0) }
        driver.onNoUpdate = { [weak self] error in
            guard let self, self.manualCheck else { return }
            self.message = MacUpdatePresentation.noUpdate(error).localizedDescription
        }
        driver.onProgress = { [weak self] stage in self?.state = stage }
        userDriver = driver
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        sparkle = updater
        try updater.start()
        observation = updater.publisher(for: \.canCheckForUpdates).sink { [weak self] value in
            self?.canCheck = value && self?.probing == false && self?.sparkle?.sessionInProgress == false
        }
        installation.isIdle = { [weak self] in self?.isIdle() == true }
        installation.onDeferred = { [weak self] in
            self?.releaseInstallation()
            self?.state = .deferred
        }
        installation.onFailure = { [weak self] in self?.fail($0) }
        guard let service else { throw MacManagementError.configuration }
        scheduler.isSessionActive = { [weak self] in
            guard let self else { return true }
            return self.isTerminating || self.sparkle?.sessionInProgress != false || self.hasDeferredInstallation || self.installationCommitted
        }
        scheduler.onChecking = { [weak self] checking in
            self?.probing = checking
            self?.canCheck = !checking && self?.sparkle?.canCheckForUpdates == true && self?.sparkle?.sessionInProgress == false
        }
        scheduler.onFailure = { [weak self] in self?.fail($0) }
        // 应用拥有唯一的 300 秒调度；不与 Sparkle 的另一套定时器并行。
        scheduler.start(status: { try await service.status() }, perform: { [weak self] manual in
            guard let self else { return }
            self.manualCheck = manual
            self.message = nil
            self.sparkle?.checkForUpdates()
        })
        automaticUpdatesEnabled = scheduler.isEnabled
        MacAutomaticUpdateTermination.controller = self
    }

    func checkForUpdates() {
        guard !probing, sparkle?.sessionInProgress == false, !hasDeferredInstallation else { return }
        checkTask = Task { [weak self] in await self?.scheduler.check(manual: true) }
    }

    func verifyCurrentRelease() async throws {
        guard let expected = sessionID, let target, let verifier else { throw MacManagementError.updateCancelled }
        try await verifier.check(target, currentBuild: currentBuild)
        try Task.checkCancellation()
        guard sessionID == expected, self.target == target else { throw CancellationError() }
    }

    func deferInstallation(install: @escaping () -> Void, cancel: @escaping () -> Void) {
        guard sessionIsCurrent else { cancel(); return }
        state = .downloaded
        let expected = sessionID
        installation.submit(verify: { [weak self] in
            guard let self, self.sessionID == expected else { throw CancellationError() }
            try await self.verifyCurrentRelease()
            if self.isIdle() {
                guard await self.reserveInstallation() else { throw MacManagementError.streaming }
                guard self.sessionID == expected, self.isIdle() else {
                    self.releaseInstallation()
                    throw MacManagementError.streaming
                }
            }
        }, install: { [weak self] in
            guard let self, self.sessionID == expected, let target = self.target,
                  let completion = self.completion else { throw MacManagementError.updateCancelled }
            try completion.prepare(target.release)
            self.installationCommitted = true
            self.state = .installing
            self.log.record("更新校验通过，当前空闲，开始自动安装并重新启动")
            install()
        }, cancel: cancel)
    }

    func fail(_ error: Error) {
        guard !stopping else { return }
        stopping = true
        sessionID = nil
        target = nil
        installationCommitted = false
        installation.cancel()
        userDriver?.cancelCurrentInteraction()
        releaseInstallation()
        message = MacUpdatePresentation.failureMessage(error)
        do { if completion?.state(currentBuild: currentBuild) != .installed { try completion?.clear() } }
        catch { message = "更新状态保存失败：\(error.localizedDescription)" }
        state = .failed
        log.recordPeriodic("自动更新已停止：\(message ?? "更新失败")", key: "自动更新错误", intervalNanoseconds: 300_000_000_000)
        stopping = false
    }

    func acknowledgeInstalledBuild(_ build: String) throws {
        guard build == currentBuild, completion?.state(currentBuild: build) == .installed else { return }
        try completion?.clear()
    }

    var buttonTitle: String {
        switch state {
        case .checking: "正在检查更新"
        case .available, .downloading: "正在下载更新"
        case .downloaded: "正在准备更新"
        case .deferred: "空闲后自动更新"
        case .installing: "正在安装更新"
        case .failed: "更新失败，点击重试"
        default: "检查更新"
        }
    }
}
