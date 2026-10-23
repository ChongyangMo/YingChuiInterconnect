import Foundation
import XCTest
@testable import YingchuiMac

private actor ManagementServiceDouble: MacManagementService {
    var sent = 0
    var continuation: CheckedContinuation<MacHeartbeatReceipt, Error>?
    func status() async throws -> MacManagementStatus {
        .init(contract_version: "mac-management-v1", management_available: true, updates_available: true)
    }
    func heartbeat(_ payload: MacHeartbeat, token: String) async throws -> MacHeartbeatReceipt {
        sent += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish() {
        continuation?.resume(returning: .init(contract_version: "mac-management-v1", next_heartbeat_seconds: 300, update_available: false, latest_build: nil))
        continuation = nil
    }
}

@MainActor
final class MacManagementTests: XCTestCase {
    private var configuration: MacManagementConfiguration {
        .init(baseURL: URL(string: "https://chongyang.asia")!, contractVersion: "mac-management-v1", channel: .stable, useSystemProxy: false)
    }
    private var payload: MacHeartbeat {
        .init(installation_id: UUID().uuidString, app_version: "1.0", app_build: "2", os_version: "15.0.0",
              architecture: "arm64", service_running: true, streaming: false, update_state: .idle, channel: .unified, automatic_updates: true)
    }

    func testAuthenticatedHeartbeatContainsOnlyAgreedFields() async throws {
        let transport = AccountTransportDouble(json: "{\"contract_version\":\"mac-management-v1\",\"next_heartbeat_seconds\":300,\"update_available\":false,\"latest_build\":null}")
        let api = try MacManagementAPI(configuration: configuration, transport: transport)
        _ = try await api.heartbeat(payload, token: "unit-only")
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://chongyang.asia/api/yingchui/v1/mac/heartbeat")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-only")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client-ID"), "com.yingchui.interconnect.mac")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), Set(["installation_id", "app_version", "app_build", "os_version", "architecture", "service_running", "streaming", "update_state", "channel", "automatic_updates"]))
    }

    func testPublicStatusDoesNotCarryAccountToken() async throws {
        let transport = AccountTransportDouble(json: "{\"contract_version\":\"mac-management-v1\",\"management_available\":true,\"updates_available\":false}")
        let api = try MacManagementAPI(configuration: configuration, transport: transport)
        let status = try await api.status()
        XCTAssertFalse(status.updates_available)
        let requests = await transport.requests
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(configuration.feedURL.path, "/updates/yingchui/mac/\(MacUpdateSourcePolicy.architecture)/\(MacUpdateSourcePolicy.osVersion)/appcast.xml")
    }

    func testNotDeployedAndInvalidContractDoNotPretendSuccess() async throws {
        for (http, body) in [(404, "{}"), (200, "{\"contract_version\":\"wrong\",\"management_available\":true,\"updates_available\":true}")] {
            let api = try MacManagementAPI(configuration: configuration, transport: AccountTransportDouble(status: http, json: body))
            do { _ = try await api.status(); XCTFail("未部署或契约错误必须报错") }
            catch { XCTAssertTrue(error is MacManagementError) }
        }
        for interval in [0, 59, 3601] {
            XCTAssertThrowsError(try MacHeartbeatReceipt(contract_version: "mac-management-v1", next_heartbeat_seconds: interval,
                update_available: false, latest_build: nil).validate())
        }
        XCTAssertThrowsError(try MacHeartbeatReceipt(contract_version: "mac-management-v1", next_heartbeat_seconds: 300,
            update_available: true, latest_build: nil).validate())
    }

    func testInstallationIdentityPersistsAndCorruptionIsNotReplaced() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("installation.json")
        let id = try MacInstallationIdentity.load(at: url)
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertEqual(id, id.lowercased())
        XCTAssertEqual(id.split(separator: "-")[2].first, "4")
        XCTAssertEqual(try MacInstallationIdentity.load(at: url), id)
        try Data("损坏".utf8).write(to: url)
        XCTAssertThrowsError(try MacInstallationIdentity.load(at: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "损坏")
    }

    func testLogoutInvalidatesInFlightHeartbeatAndAnonymousCannotSend() async throws {
        let session = accountTestSession()
        let accountService = AccountServiceDouble()
        accountService.confirmedUser = session.user
        let sessions = AccountSessionController(service: accountService, store: AccountMemoryStore())
        try await sessions.accept(session, expected: sessions.generation)
        let service = ManagementServiceDouble()
        let payload = payload
        let task = Task { try await MacHeartbeatOperation.send(payload, service: service, sessions: sessions) }
        for _ in 0..<100 {
            if await service.sent == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let sent = await service.sent
        XCTAssertEqual(sent, 1)
        try await sessions.signOut()
        await service.finish()
        do { _ = try await task.value; XCTFail("退出后旧心跳不得确认成功") }
        catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await MacHeartbeatOperation.send(payload, service: service, sessions: sessions); XCTFail("未登录不得发心跳") }
        catch { XCTAssertEqual(error as? MacManagementError, .unauthorized) }
        let total = await service.sent
        XCTAssertEqual(total, 1)
    }

    func testBuildNumbersFollowFinalBackendContract() {
        for value in ["0", "1", "1.0", "1.0.2", "999999999999999999.1.2"] {
            XCTAssertTrue(MacBuildNumber.isValid(value), value)
        }
        for value in ["", "01", "1.00", "1.2.3.4", "1..2", "1000000000000000000", "1.beta", "-1"] {
            XCTAssertFalse(MacBuildNumber.isValid(value), value)
        }
    }

    func testOnlyVersionedSameOriginSignedArtifactLocationsAreAccepted() throws {
        let path = "/updates/yingchui/mac/artifacts/" + String(repeating: "a", count: 64) + "/YingchuiMac.zip"
        try MacUpdateSourcePolicy.validateArtifact(URL(string: "https://chongyang.asia" + path), build: "2.1", size: 100)
        for source in ["http://chongyang.asia" + path, "https://evil.example" + path,
                       "https://chongyang.asia" + path + "?token=private", "https://chongyang.asia/other/app.zip"] {
            XCTAssertThrowsError(try MacUpdateSourcePolicy.validateArtifact(URL(string: source), build: "2", size: 100))
        }
        XCTAssertThrowsError(try MacUpdateSourcePolicy.validateArtifact(URL(string: "https://chongyang.asia" + path), build: "beta", size: 100))
    }
}
