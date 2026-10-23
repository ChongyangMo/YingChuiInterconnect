import Foundation

// 网络队列撤销配对时立即失效，阻止主线程上迟到的账号请求提交。
final class AccountLinkLease: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var active = true
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    func invalidate() { lock.lock(); active = false; lock.unlock() }
}
