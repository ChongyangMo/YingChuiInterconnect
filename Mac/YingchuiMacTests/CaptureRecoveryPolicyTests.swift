import XCTest
@testable import YingchuiMac

final class CaptureRecoveryPolicyTests: XCTestCase {
    func testReceiverCanRefreshQuietIdleSourceWithoutTreatingIdleAsFailure() {
        let policy = MacCaptureRecoveryPolicy()
        XCTAssertFalse(policy.shouldRecover(lastCapture: 0, wasComplete: false, isRecovering: false,
            receiverRequestedRefresh: true, now: 499_999_999))
        XCTAssertTrue(policy.shouldRecover(lastCapture: 0, wasComplete: false, isRecovering: false,
            receiverRequestedRefresh: true, now: 500_000_000))
        XCTAssertFalse(policy.shouldRecover(lastCapture: 0, wasComplete: false, isRecovering: true,
            receiverRequestedRefresh: true, now: 5_000_000_000))
        XCTAssertFalse(policy.shouldRecover(lastCapture: nil, wasComplete: false, isRecovering: false,
            receiverRequestedRefresh: true, now: 5_000_000_000))
    }

    func testNoRecoveryForStartupIdleSuspendedOrActiveRecovery() {
        let policy = MacCaptureRecoveryPolicy()
        XCTAssertFalse(policy.shouldRecover(lastCapture: nil, wasComplete: true, isRecovering: false, now: 5_000_000_000))
        XCTAssertFalse(policy.shouldRecover(lastCapture: 0, wasComplete: false, isRecovering: false, now: 5_000_000_000))
        XCTAssertFalse(policy.shouldRecover(lastCapture: 0, wasComplete: true, isRecovering: true, now: 5_000_000_000))
        XCTAssertFalse(policy.shouldRecover(lastCapture: 100, wasComplete: true, isRecovering: false, now: 99))
    }

    func testInteractiveStallRecoversFasterButHealthyFramesDoNotRestart() {
        var policy = MacCaptureRecoveryPolicy()
        XCTAssertFalse(policy.shouldRecover(lastCapture: 0, wasComplete: true, isRecovering: false, now: 499_999_999))
        XCTAssertTrue(policy.shouldRecover(lastCapture: 0, wasComplete: true, isRecovering: false, now: 500_000_000))
        policy.recordInteraction(now: 100_000_000)
        XCTAssertFalse(policy.shouldRecover(lastCapture: 0, wasComplete: true, isRecovering: false, now: 199_999_999))
        XCTAssertTrue(policy.shouldRecover(lastCapture: 0, wasComplete: true, isRecovering: false, now: 200_000_000))
        XCTAssertFalse(policy.shouldRecover(lastCapture: 190_000_000, wasComplete: true, isRecovering: false, now: 200_000_000))
        XCTAssertFalse(policy.shouldRecover(lastCapture: 1_000_000_000, wasComplete: true, isRecovering: false, now: 1_400_000_000))
    }

    func testRecoveryCannotLoopWithoutBoundAndWindowExpires() {
        var policy = MacCaptureRecoveryPolicy()
        XCTAssertTrue(policy.beginRecovery(now: 0))
        XCTAssertTrue(policy.beginRecovery(now: 1_000_000_000))
        XCTAssertTrue(policy.beginRecovery(now: 2_000_000_000))
        XCTAssertFalse(policy.beginRecovery(now: 9_999_999_999))
        XCTAssertTrue(policy.beginRecovery(now: 10_000_000_000))
        XCTAssertFalse(policy.beginRecovery(now: 10_000_000_001))
    }

    func testStableRecoveryAllowsLaterMenuInteractions() {
        var policy = MacCaptureRecoveryPolicy()
        for index in 0..<3 { XCTAssertTrue(policy.beginRecovery(now: UInt64(index))) }
        for index in 0...10 { policy.recordCapture(now: 10 + UInt64(index) * 100_000_000) }
        XCTAssertTrue(policy.beginRecovery(now: 1_100_000_000))
    }

    func testIsolatedFramesDoNotHideRepeatedRecoveryFailure() {
        var policy = MacCaptureRecoveryPolicy()
        for index in 0..<3 {
            let now = UInt64(index) * 1_000_000_000
            XCTAssertTrue(policy.beginRecovery(now: now))
            policy.recordCapture(now: now + 100_000_000)
        }
        XCTAssertFalse(policy.beginRecovery(now: 3_000_000_000))
    }
}
