import Foundation
import IOKit.pwr_mgt
import XCTest
@testable import YingchuiMac

private final class FakePowerDriver: MacPowerAssertionDriving {
    var acquired = 0
    var released: [IOPMAssertionID] = []
    var wakeCount = 0
    var failWake = false
    var failAcquire = false
    var failRelease = false

    func acquire() throws -> IOPMAssertionID {
        if failAcquire { throw MacStreamPowerError.system("测试启用", kIOReturnError) }
        acquired += 1
        return 42
    }
    func wakeDisplay() throws -> IOPMAssertionID {
        if failWake { throw MacStreamPowerError.system("测试唤醒", kIOReturnError) }
        wakeCount += 1
        return 43
    }
    func releaseWake(_ id: IOPMAssertionID) throws { try release(id) }
    func release(_ id: IOPMAssertionID) throws {
        if failRelease { throw MacStreamPowerError.system("测试释放", kIOReturnError) }
        released.append(id)
    }
}

final class StreamPowerTests: XCTestCase {
    func testWakeRequiresActiveStreamAndOnlyRunsOncePerSession() throws {
        let driver = FakePowerDriver()
        let activity = MacStreamPowerActivity(driver: driver)
        XCTAssertThrowsError(try activity.wakeDisplayForStream())
        try activity.begin()
        try activity.wakeDisplayForStream()
        try activity.wakeDisplayForStream()
        XCTAssertEqual(driver.wakeCount, 1)
        try activity.end()
        XCTAssertEqual(driver.released, [43, 42])
        try activity.begin()
        try activity.wakeDisplayForStream()
        XCTAssertEqual(driver.wakeCount, 2)
        try activity.end()
    }

    func testWakeFailureIsReportedAndProtectionCanBeReleased() throws {
        let driver = FakePowerDriver()
        let activity = MacStreamPowerActivity(driver: driver)
        try activity.begin()
        driver.failWake = true
        XCTAssertThrowsError(try activity.wakeDisplayForStream())
        try activity.end()
        XCTAssertEqual(driver.released, [42])
        XCTAssertFalse(activity.isActive)
    }

    func testSystemDeclaresAndReleasesDisplayWake() throws {
        let driver = SystemStreamPowerAssertion()
        let id = try driver.wakeDisplay()
        let properties = IOPMAssertionCopyProperties(id)?.takeRetainedValue() as? [String: Any]
        try driver.releaseWake(id)
        XCTAssertEqual(try XCTUnwrap(properties)[kIOPMAssertionTypeKey] as? String, "UserIsActive")
        XCTAssertNil(IOPMAssertionCopyProperties(id))
    }

    func testActivityAcquiresOnceAndReleasesOnce() throws {
        let driver = FakePowerDriver()
        let lease = MacStreamPowerActivity(driver: driver)
        XCTAssertFalse(lease.isActive)
        try lease.begin()
        try lease.begin()
        XCTAssertTrue(lease.isActive)
        XCTAssertEqual(driver.acquired, 1)
        try lease.end()
        try lease.end()
        XCTAssertFalse(lease.isActive)
        XCTAssertEqual(driver.released, [42])
    }

    func testAcquireFailureDoesNotPretendProtectionIsActive() {
        let driver = FakePowerDriver()
        driver.failAcquire = true
        let activity = MacStreamPowerActivity(driver: driver)
        XCTAssertThrowsError(try activity.begin())
        XCTAssertFalse(activity.isActive)
    }

    func testReleaseFailureKeepsHandleForExplicitRetry() throws {
        let driver = FakePowerDriver()
        let lease = MacStreamPowerActivity(driver: driver)
        try lease.begin()
        driver.failRelease = true
        XCTAssertThrowsError(try lease.end())
        XCTAssertTrue(lease.isActive)
        driver.failRelease = false
        try lease.end()
        XCTAssertFalse(lease.isActive)
        XCTAssertEqual(driver.released, [42])
    }

    func testSystemCreatesAndReleasesDisplaySleepAssertion() throws {
        let driver = SystemStreamPowerAssertion()
        let id = try driver.acquire()
        let copied = IOPMAssertionCopyProperties(id)?.takeRetainedValue() as? [String: Any]
        try driver.release(id)
        let properties = try XCTUnwrap(copied)
        XCTAssertEqual(properties[kIOPMAssertionTypeKey] as? String, kIOPMAssertionTypePreventUserIdleDisplaySleep)
        XCTAssertNil(IOPMAssertionCopyProperties(id))
    }

    func testServiceStopReleasesPowerAndClearsStaleController() throws {
        let host = MacHostModel(startServices: false)
        try host.streamPowerActivity.begin()
        host.controlSessionID = UUID()
        host.stopOnNetworkQueue(publish: false)
        XCTAssertFalse(host.streamPowerActivity.isActive)
        XCTAssertNil(host.controlSessionID)
        XCTAssertTrue(host.sessions.isEmpty)
    }
}
