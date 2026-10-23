import ServiceManagement
import XCTest
@testable import YingchuiMac

final class LaunchAtLoginTests: XCTestCase {
    func testFirstLaunchNotFoundRegistersInsteadOfSilentlyReturning() throws {
        let service = LoginServiceStub(status: .notFound)
        try LaunchAtLoginController.setEnabled(true, service: service)
        XCTAssertEqual(service.registrations, 1)
        XCTAssertEqual(service.status, .enabled)
        XCTAssertEqual(LaunchAtLoginController.state(for: .notFound), .notFound)
    }

    func testUnregisteredServiceCanBeEnabledAndDisabled() throws {
        let service = LoginServiceStub(status: .notRegistered)
        try LaunchAtLoginController.setEnabled(true, service: service)
        try LaunchAtLoginController.setEnabled(false, service: service)
        XCTAssertEqual(service.registrations, 1)
        XCTAssertEqual(service.unregistrations, 1)
        XCTAssertEqual(service.status, .notRegistered)
    }

    func testApprovalIsPreservedWithoutRegisteringAgain() throws {
        let service = LoginServiceStub(status: .requiresApproval)
        try LaunchAtLoginController.setEnabled(true, service: service)
        XCTAssertEqual(service.registrations, 0)
        XCTAssertEqual(LaunchAtLoginController.state(for: service.status), .needsApproval)
        XCTAssertTrue(LaunchAtLoginController.state(for: service.status).isSelected)
        try LaunchAtLoginController.setEnabled(false, service: service)
        XCTAssertEqual(service.unregistrations, 1)
    }

    func testRepeatedSelectionDoesNotRegisterOrUnregisterTwice() throws {
        let service = LoginServiceStub(status: .enabled)
        try LaunchAtLoginController.setEnabled(true, service: service)
        XCTAssertEqual(service.registrations, 0)
        service.status = .notRegistered
        try LaunchAtLoginController.setEnabled(false, service: service)
        XCTAssertEqual(service.unregistrations, 0)
    }

    func testRegistrationErrorIsPropagated() {
        let service = LoginServiceStub(status: .notFound)
        service.error = NSError(domain: "登录项测试", code: 17)
        XCTAssertThrowsError(try LaunchAtLoginController.setEnabled(true, service: service)) {
            XCTAssertEqual(($0 as NSError).domain, "登录项测试")
            XCTAssertEqual(($0 as NSError).code, 17)
        }
        XCTAssertEqual(service.status, .notFound)
    }

    func testUnconfirmedSystemChangesAreReportedAsErrors() {
        let service = LoginServiceStub(status: .notFound)
        service.appliesChanges = false
        XCTAssertThrowsError(try LaunchAtLoginController.setEnabled(true, service: service))
        service.status = .enabled
        XCTAssertThrowsError(try LaunchAtLoginController.setEnabled(false, service: service))
    }
}

private final class LoginServiceStub: LaunchAtLoginService {
    var status: SMAppService.Status
    var registrations = 0
    var unregistrations = 0
    var error: NSError?
    var appliesChanges = true

    init(status: SMAppService.Status) { self.status = status }

    func register() throws {
        registrations += 1
        if let error { throw error }
        if appliesChanges { status = .enabled }
    }

    func unregister() throws {
        unregistrations += 1
        if let error { throw error }
        if appliesChanges { status = .notRegistered }
    }
}
