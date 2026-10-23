import Foundation
import IOKit.pwr_mgt
import YingchuiProtocol

protocol MacPowerAssertionDriving {
    func acquire() throws -> IOPMAssertionID
    func release(_ id: IOPMAssertionID) throws
    func wakeDisplay() throws -> IOPMAssertionID
    func releaseWake(_ id: IOPMAssertionID) throws
}

/// 仅由回传持有；不修改系统息屏设置，不阻止用户主动休眠。
final class MacStreamPowerActivity: @unchecked Sendable {
    private let lock = NSLock()
    private let driver: MacPowerAssertionDriving
    private var assertionID: IOPMAssertionID?
    private var wakeAssertionID: IOPMAssertionID?
    private let eventLog = DiagnosticEventLog(subsystem: "com.yingchui.interconnect.mac", category: "回传电源")
    var isActive: Bool { lock.withLock { assertionID != nil } }

    init(driver: MacPowerAssertionDriving = SystemStreamPowerAssertion()) {
        self.driver = driver
    }

    func begin() throws {
        try lock.withLock {
            guard assertionID == nil else { return }
            assertionID = try driver.acquire()
            eventLog.record("回传保活已启用：阻止自动息屏和空闲休眠")
        }
    }

    /// 虚拟显示器建立后调用一次。防止息屏的断言本身不能点亮已经熄灭的桌面。
    func wakeDisplayForStream() throws {
        try lock.withLock {
            guard assertionID != nil else { throw MacStreamPowerError.inactive }
            guard wakeAssertionID == nil else { return }
            wakeAssertionID = try driver.wakeDisplay()
            eventLog.record("已请求唤醒回传显示器，无需鼠标点击")
        }
    }

    func end() throws {
        try lock.withLock {
            if let wakeAssertionID {
                try driver.releaseWake(wakeAssertionID)
                self.wakeAssertionID = nil
            }
            guard let assertionID else { return }
            try driver.release(assertionID)
            self.assertionID = nil
            eventLog.record("回传保活已释放：恢复系统原有息屏策略")
        }
    }

    deinit {
        do { try end() }
        catch { eventLog.record("退出时释放回传保活失败：\(error.localizedDescription)") }
    }
}

struct SystemStreamPowerAssertion: MacPowerAssertionDriving {
    func acquire() throws -> IOPMAssertionID {
        var id = IOPMAssertionID(0)
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "鹰锤互联正在向 iPad 回传画面" as CFString, &id
        )
        guard status == kIOReturnSuccess else { throw MacStreamPowerError.system("启用回传保活", status) }
        return id
    }

    func wakeDisplay() throws -> IOPMAssertionID {
        var id = IOPMAssertionID(0)
        let status = IOPMAssertionDeclareUserActivity(
            "鹰锤互联开始显示 iPad 回传桌面" as CFString, kIOPMUserActiveLocal, &id
        )
        guard status == kIOReturnSuccess else { throw MacStreamPowerError.system("唤醒回传显示器", status) }
        return id
    }

    func releaseWake(_ id: IOPMAssertionID) throws {
        // UserIsActive 受系统超时管理，已到期销毁的断言不需要再次释放。
        guard IOPMAssertionCopyProperties(id)?.takeRetainedValue() != nil else { return }
        try release(id)
    }

    func release(_ id: IOPMAssertionID) throws {
        let status = IOPMAssertionRelease(id)
        guard status == kIOReturnSuccess else { throw MacStreamPowerError.system("释放回传保活", status) }
    }
}

enum MacStreamPowerError: LocalizedError {
    case system(String, IOReturn)
    case inactive
    var errorDescription: String? {
        switch self {
        case .inactive: "回传电源保护未启用，无法唤醒显示器"
        case .system(let operation, let status): "\(operation)失败（\(status)）"
        }
    }
}
