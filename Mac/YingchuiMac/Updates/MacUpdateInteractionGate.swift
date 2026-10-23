import Foundation

/// 系统更新界面的回调只能完成一次；下载结束后不得再调用下载取消回调。
@MainActor
final class MacUpdateInteractionGate {
    private var pending: (UUID, () -> Void)?

    func registerCancellation(_ action: @escaping () -> Void) -> UUID {
        let id = UUID()
        pending = (id, action)
        return id
    }

    func complete(_ id: UUID, action: () -> Void) {
        guard pending?.0 == id else { return }
        pending = nil
        action()
    }

    func clear() { pending = nil }

    func cancel() {
        let action = pending?.1
        pending = nil
        action?()
    }
}
