import AppKit
import Sparkle

/// 更新状态显示在应用设置中；确认下载与空闲安装采用用户已开启的自动更新策略。
@MainActor
final class MacUpdateUserDriver: SPUStandardUserDriver {
    var allowsSession: () -> Bool = { false }
    var verifyDownload: () async throws -> Void = {}
    var prepareInstallation: (@escaping () -> Void, @escaping () -> Void) -> Void = { _, cancel in cancel() }
    var onFailure: (Error) -> Void = { _ in }
    var onNoUpdate: (Error) -> Void = { _ in }
    var onProgress: (MacUpdateState) -> Void = { _ in }
    private let gate = MacUpdateInteractionGate()
    private var verification: Task<Void, Never>?
    private var terminationRetry: (() -> Void)?
    private var terminationRetryRequested = false
    private var committedCancellation: (() -> Void)?

    func cancelCurrentInteraction() {
        verification?.cancel()
        verification = nil
        terminationRetry = nil
        terminationRetryRequested = false
        gate.cancel()
        // 系统拒绝退出后仍可能保留待安装程序；用公开的取消响应结束它。
        let cancel = committedCancellation
        committedCancellation = nil
        cancel?()
    }

    func retryTerminationWhenIdle() {
        terminationRetryRequested = true
        scheduleTerminationRetryIfReady()
    }

    private func scheduleTerminationRetryIfReady() {
        guard terminationRetryRequested, let retry = terminationRetry else { return }
        terminationRetryRequested = false
        prepareInstallation(retry, { [weak self] in self?.cancelCurrentInteraction() })
    }

    override func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        guard allowsSession() else { cancellation(); return }
        _ = gate.registerCancellation(cancellation)
    }
    override func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState,
                                  reply: @escaping (SPUUserUpdateChoice) -> Void) {
        gate.clear()
        guard allowsSession() else { reply(.skip); return }
        if state.stage == .installing {
            showReady(toInstallAndRelaunch: reply)
            return
        }
        let id = gate.registerCancellation { reply(.skip) }
        verification = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.verifyDownload()
                try Task.checkCancellation()
                guard self.allowsSession() else { throw CancellationError() }
                self.gate.complete(id) { reply(.install) }
            } catch {
                self.gate.complete(id) { reply(.skip); self.onFailure(error) }
            }
        }
    }
    override func showDownloadInitiated(cancellation: @escaping () -> Void) {
        gate.clear()
        guard allowsSession() else { cancellation(); return }
        _ = gate.registerCancellation(cancellation)
        onProgress(.downloading)
    }
    override func showDownloadDidReceiveExpectedContentLength(_ length: UInt64) {}
    override func showDownloadDidReceiveData(ofLength length: UInt64) {}
    override func showDownloadDidStartExtractingUpdate() { gate.clear(); onProgress(.downloaded) }
    override func showExtractionReceivedProgress(_ progress: Double) {}
    override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        gate.clear()
        guard allowsSession() else { reply(.skip); return }
        let id = gate.registerCancellation { reply(.skip) }
        prepareInstallation({ [weak self] in
            self?.gate.complete(id) {
                self?.committedCancellation = { reply(.skip) }
                reply(.install)
            }
        }, { [weak self] in self?.gate.complete(id) { reply(.skip) } })
    }
    override func showInstallingUpdate(withApplicationTerminated terminated: Bool,
                                      retryTerminatingApplication retry: @escaping () -> Void) {
        guard !terminated else { return }
        terminationRetry = retry
        scheduleTerminationRetryIfReady()
    }
    override func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        committedCancellation = nil
        acknowledgement()
    }
    override func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        gate.clear(); onNoUpdate(error); acknowledgement()
    }
    override func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        committedCancellation = nil
        gate.clear(); onFailure(error); acknowledgement()
    }
    override func dismissUpdateInstallation() { cancelCurrentInteraction() }
}
