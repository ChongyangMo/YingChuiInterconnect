import Foundation

public final class SynchronizedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    public init(_ value: Value) {
        storedValue = value
    }

    public var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    public func set(_ value: Value) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    @discardableResult
    public func mutate<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&storedValue)
    }
}
