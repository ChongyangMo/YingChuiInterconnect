import Foundation

@MainActor
final class MacAutomaticUpdateScheduler {
    var isSessionActive: () -> Bool = { false }
    var onChecking: (Bool) -> Void = { _ in }
    var onFailure: (Error) -> Void = { _ in }
    private var status: (() async throws -> MacManagementStatus)?
    private var perform: ((Bool) -> Void)?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private(set) var isChecking = false
    private(set) var isEnabled = false

    func start(interval: Duration = .seconds(300), status: @escaping () async throws -> MacManagementStatus,
               perform: @escaping (Bool) -> Void) {
        guard !isEnabled else { return }
        self.status = status
        self.perform = perform
        isEnabled = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.check()
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    func check(manual: Bool = false) async {
        guard isEnabled, !isChecking, !isSessionActive(), let status else { return }
        let expected = generation
        isChecking = true
        onChecking(true)
        defer { if generation == expected { isChecking = false; onChecking(false) } }
        do {
            let result = try await status()
            try Task.checkCancellation()
            guard generation == expected, isEnabled else { return }
            try result.validateAutomaticUpdates()
            guard !isSessionActive() else { return }
            perform?(manual)
        } catch is CancellationError { return }
        catch { if generation == expected { onFailure(error) } }
    }

    func stop() {
        generation = UUID()
        isEnabled = false
        isChecking = false
        task?.cancel()
        task = nil
        onChecking(false)
    }
}
