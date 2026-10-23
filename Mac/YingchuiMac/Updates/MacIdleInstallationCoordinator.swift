import Foundation

/// 只持有一个安装回调。验证期间再次变忙、取消或旧响应迟到均不能继续安装。
@MainActor
final class MacIdleInstallationCoordinator {
    struct Pending {
        let id: UUID
        let verify: () async throws -> Void
        let install: () throws -> Void
        let cancel: () -> Void
    }
    var isIdle: () -> Bool = { false }
    var onDeferred: () -> Void = {}
    var onFailure: (Error) -> Void = { _ in }
    private var pending: Pending?
    private var verification: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var lastValidation = Date.distantPast
    private var generation = UUID()
    var hasPendingInstallation: Bool { pending != nil }

    func submit(verify: @escaping () async throws -> Void, install: @escaping () throws -> Void,
                cancel: @escaping () -> Void, startTimer: Bool = true) {
        self.cancel()
        pending = Pending(id: UUID(), verify: verify, install: install, cancel: cancel)
        generation = pending!.id
        lastValidation = .distantPast
        tick()
        if startTimer {
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard let self, self.pending != nil else { return }
                    self.tick()
                }
            }
        }
    }

    func tick(now: Date = Date()) {
        guard let item = pending, verification == nil else { return }
        guard isIdle() || now.timeIntervalSince(lastValidation) >= 300 else { onDeferred(); return }
        verification = Task { [weak self] in
            guard let self else { return }
            do {
                try await item.verify()
                try Task.checkCancellation()
                guard self.pending?.id == item.id else { return }
                self.lastValidation = now
                self.verification = nil
                guard self.isIdle() else { self.onDeferred(); return }
                // 先清空，安装回调可安全提交下一阶段，不重入旧操作。
                self.pending = nil
                self.timer?.cancel()
                self.timer = nil
                try item.install()
            } catch {
                guard self.generation == item.id else { return }
                if error as? MacManagementError == .streaming {
                    self.verification = nil
                    self.onDeferred()
                    return
                }
                self.pending = nil
                self.verification = nil
                self.timer?.cancel()
                self.timer = nil
                item.cancel()
                self.onFailure(error)
            }
        }
    }

    func cancel() {
        generation = UUID()
        let item = pending
        pending = nil
        verification?.cancel()
        verification = nil
        timer?.cancel()
        timer = nil
        item?.cancel()
    }
}
