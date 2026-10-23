import AppKit
import Sparkle
import XCTest
@testable import YingchuiMac

private actor ReleaseResponse: AccountHTTPTransport {
    let body: String
    let code: Int
    let mime: String
    var requests: [URLRequest] = []
    init(_ body: String, code: Int = 200, mime: String = "application/rss+xml") {
        self.body = body; self.code = code; self.mime = mime
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil,
                                               headerFields: ["Content-Type": mime])!)
    }
}

@MainActor
final class MacAutomaticUpdateTests: XCTestCase {
    private var policy: MacAutomaticUpdatePolicy {
        .init(mode: "automatic", check_interval_seconds: 300, install_when_idle: true)
    }
    private var status: MacManagementStatus {
        .init(contract_version: "mac-management-v1", management_available: true, updates_available: true,
              push_available: false, update_policy: policy)
    }
    private var target: MacAutomaticUpdateTarget {
        let digest = String(repeating: "a", count: 64)
        return .init(release: .init(release_id: digest, app_version: "1.1.0", app_build: "999",
                                   appcast_url: MacUpdateSourcePolicy.fixedFeed(releaseID: digest)),
                     artifactURL: URL(string: "https://chongyang.asia/updates/yingchui/mac/artifacts/\(digest)/app.zip")!, size: 1234)
    }
    private var feed: String {
        """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
        <sparkle:version>999</sparkle:version><sparkle:shortVersionString>1.1.0</sparkle:shortVersionString>
        <sparkle:minimumSystemVersion>15.0.0</sparkle:minimumSystemVersion>
        <enclosure url="\(target.artifactURL)" length="1234" sparkle:edSignature="\(Data(repeating: 1, count: 64).base64EncodedString())"/>
        </item></channel></rss>
        """
    }
    private func until(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("等待异步操作超时", file: file, line: line)
    }

    func testUnifiedFeedUsesActualArchitectureAndOSWithoutAccountOrChannel() throws {
        for channel in [MacReleaseChannel.stable, .beta, .unified] {
            let config = MacManagementConfiguration(baseURL: URL(string: "https://chongyang.asia")!,
                contractVersion: "mac-management-v1", channel: channel, useSystemProxy: false)
            XCTAssertEqual(config.feedURL.path, "/updates/yingchui/mac/\(MacUpdateSourcePolicy.architecture)/\(MacUpdateSourcePolicy.osVersion)/appcast.xml")
        }
        try target.validate(currentBuild: "10")
        for current in ["999", "1000", "999.0", "", "broken"] { XCTAssertThrowsError(try target.validate(currentBuild: current)) }
        let invalid = MacAvailableUpdate(release_id: target.release.release_id, app_version: "1.1.0", app_build: "999",
                                         appcast_url: URL(string: target.release.appcast_url.absoluteString + "?other=1")!)
        XCTAssertThrowsError(try invalid.validate())
    }

    func testOldBackendAndChangedPolicyAreExplicitlyRejected() throws {
        var old = status
        old.update_policy = nil
        XCTAssertThrowsError(try old.validateAutomaticUpdates()) {
            XCTAssertEqual($0 as? MacManagementError, .automaticUnavailable)
        }
        for invalid in [MacAutomaticUpdatePolicy(mode: "manual", check_interval_seconds: 300, install_when_idle: true),
                        .init(mode: "automatic", check_interval_seconds: 0, install_when_idle: true),
                        .init(mode: "automatic", check_interval_seconds: 300, install_when_idle: false)] {
            XCTAssertThrowsError(try invalid.validate())
        }
        var receipt = MacHeartbeatReceipt(contract_version: "mac-management-v1", next_heartbeat_seconds: 300,
            update_available: true, latest_build: "999", available_update: target.release, update_policy: policy)
        try receipt.validate()
        receipt.available_update = nil
        XCTAssertThrowsError(try receipt.validate())
    }

    func testPublishedReleaseRecheckHasNoCredentialsAndMatchesExactArtifact() async throws {
        let transport = ReleaseResponse(feed)
        try await MacPublishedReleaseVerifier(transport: transport).check(target, currentBuild: "10")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url, target.release.appcast_url)
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(requests[0].cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testWithdrawnUnavailableAndAlteredFeedsCannotInstall() async {
        for response in [ReleaseResponse(feed, code: 410), ReleaseResponse(feed, code: 404),
                         ReleaseResponse("<html>错误</html>", mime: "text/html"),
                         ReleaseResponse("<rss><channel/></rss>"),
                         ReleaseResponse(feed.replacingOccurrences(of: ">999<", with: ">998<")),
                         ReleaseResponse(feed.replacingOccurrences(of: "length=\"1234\"", with: "length=\"100\"")),
                         ReleaseResponse(feed.replacingOccurrences(of: "15.0.0", with: "999.0.0")),
                         ReleaseResponse(feed.replacingOccurrences(of: "/app.zip", with: "/other.zip")),
                         ReleaseResponse(feed.replacingOccurrences(of: "</item>", with: "</item><item/>"))] {
            do { try await MacPublishedReleaseVerifier(transport: response).check(target, currentBuild: "10"); XCTFail("失效版本应停止") }
            catch { XCTAssertTrue(error is MacManagementError) }
        }
    }

    func testSchedulerChecksOnStartAndPeriodicallyWithOneActiveSession() async {
        let scheduler = MacAutomaticUpdateScheduler()
        let status = status
        var checks = 0
        var busy = false
        scheduler.isSessionActive = { busy }
        scheduler.start(interval: .milliseconds(20), status: { status }, perform: { _ in checks += 1; busy = true })
        defer { scheduler.stop() }
        await until { checks == 1 }
        for _ in 0..<4 { await scheduler.check(manual: true) }
        XCTAssertEqual(checks, 1)
        busy = false
        await until { checks == 2 }
        XCTAssertEqual(checks, 2)
    }

    func testConcurrentManualChecksAndLateStatusAfterStopAreIgnored() async {
        let scheduler = MacAutomaticUpdateScheduler()
        var continuation: CheckedContinuation<MacManagementStatus, Error>?
        var requests = 0
        var runs = 0
        scheduler.start(status: {
            requests += 1
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }, perform: { _ in runs += 1 })
        await until { continuation != nil }
        await scheduler.check(manual: true)
        XCTAssertEqual(requests, 1)
        scheduler.stop()
        continuation?.resume(returning: status)
        await Task.yield()
        XCTAssertEqual(runs, 0)
        XCTAssertFalse(scheduler.isEnabled)
    }

    func testSchedulerFailureWaitsForNextIntervalWithoutRetryLoop() async {
        let scheduler = MacAutomaticUpdateScheduler()
        var failures = 0
        var runs = 0
        scheduler.onFailure = { _ in failures += 1 }
        scheduler.start(status: { throw MacManagementError.automaticUnavailable }, perform: { _ in runs += 1 })
        defer { scheduler.stop() }
        await until { failures == 1 }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(runs, 0)
    }

    func testBusyDownloadWaitsThenResumesOnceWhenIdle() async {
        let coordinator = MacIdleInstallationCoordinator()
        var idle = false
        var installed = 0
        var deferred = 0
        coordinator.isIdle = { idle }
        coordinator.onDeferred = { deferred += 1 }
        coordinator.submit(verify: {}, install: { installed += 1 }, cancel: { XCTFail("正常延期不应取消") }, startTimer: false)
        await until { deferred == 1 }
        XCTAssertEqual(installed, 0)
        XCTAssertTrue(coordinator.hasPendingInstallation)
        idle = true
        coordinator.tick()
        coordinator.tick()
        await until { installed == 1 }
        coordinator.tick()
        XCTAssertEqual(installed, 1)
        XCTAssertFalse(coordinator.hasPendingInstallation)
    }

    func testBecomingBusyDuringVerificationCannotInstallUntilRevalidated() async {
        let coordinator = MacIdleInstallationCoordinator()
        var idle = true
        var continuation: CheckedContinuation<Void, Error>?
        var installed = 0
        var deferred = 0
        coordinator.isIdle = { idle }
        coordinator.onDeferred = { deferred += 1 }
        coordinator.submit(verify: {
            try await withCheckedThrowingContinuation { continuation = $0 }
        }, install: { installed += 1 }, cancel: {}, startTimer: false)
        await until { continuation != nil }
        idle = false
        continuation?.resume()
        continuation = nil
        await until { deferred == 1 }
        XCTAssertEqual(installed, 0)
        idle = true
        coordinator.tick()
        await until { continuation != nil }
        continuation?.resume()
        await until { installed == 1 }
    }

    func testWithdrawalWhileDeferredCancelsAndNeverResumes() async {
        let coordinator = MacIdleInstallationCoordinator()
        var cancelled = 0
        var failed = 0
        coordinator.isIdle = { false }
        coordinator.onFailure = { error in
            XCTAssertEqual(error as? MacManagementError, .releaseWithdrawn)
            failed += 1
        }
        coordinator.submit(verify: { throw MacManagementError.releaseWithdrawn },
            install: { XCTFail("撤回后不得安装") }, cancel: { cancelled += 1 }, startTimer: false)
        await until { failed == 1 }
        coordinator.isIdle = { true }
        coordinator.tick()
        XCTAssertEqual(cancelled, 1)
        XCTAssertFalse(coordinator.hasPendingInstallation)
    }

    func testCancelledVerificationCannotAffectReplacement() async {
        let coordinator = MacIdleInstallationCoordinator()
        coordinator.isIdle = { true }
        var old: CheckedContinuation<Void, Error>?
        var installed = 0
        var cancelled = 0
        var failures = 0
        coordinator.onFailure = { _ in failures += 1 }
        coordinator.submit(verify: { try await withCheckedThrowingContinuation { old = $0 } },
            install: { XCTFail("旧验证不得继续") }, cancel: { cancelled += 1 }, startTimer: false)
        await until { old != nil }
        coordinator.submit(verify: {}, install: { installed += 1 }, cancel: {}, startTimer: false)
        old?.resume(throwing: MacManagementError.releaseWithdrawn)
        await until { installed == 1 }
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(failures, 0)
    }

    func testCompletionDependsOnActualRunningBuildAndCorruptionFails() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("installation.json")
        let store = try MacUpdateCompletionStore(url: url)
        XCTAssertEqual(store.state(currentBuild: "1"), .idle)
        try store.prepare(target.release)
        let resumed = try MacUpdateCompletionStore(url: url)
        XCTAssertEqual(resumed.state(currentBuild: "998"), .failed)
        XCTAssertEqual(resumed.state(currentBuild: "999"), .installed)
        XCTAssertEqual(resumed.state(currentBuild: "1000"), .installed)
        try resumed.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try Data("损坏".utf8).write(to: url)
        XCTAssertThrowsError(try MacUpdateCompletionStore(url: url))
        XCTAssertEqual(try String(contentsOf: url), "损坏")
    }

    func testIdleChecksRealOperationsButNotListeningService() {
        XCTAssertTrue(MacUpdateIdleSnapshot().canInstall)
        for busy in [MacUpdateIdleSnapshot(streaming: true), .init(connections: 1), .init(displayRecovery: true),
                     .init(accountOperation: true), .init(unsavedEdits: true), .init(modalOperation: true)] {
            XCTAssertFalse(busy.canInstall)
        }
    }

    func testNativeReadyCallbackWaitsForIdleAndCancellationIsOnceOnly() async {
        let driver = MacUpdateUserDriver(hostBundle: .main, delegate: nil)
        let coordinator = MacIdleInstallationCoordinator()
        var idle = false
        var choices: [SPUUserUpdateChoice] = []
        driver.allowsSession = { true }
        coordinator.isIdle = { idle }
        driver.prepareInstallation = { install, cancel in
            coordinator.submit(verify: {}, install: install, cancel: cancel, startTimer: false)
        }
        driver.showReady(toInstallAndRelaunch: { choices.append($0) })
        await Task.yield()
        XCTAssertTrue(choices.isEmpty)
        idle = true
        coordinator.tick()
        await until { choices == [.install] }
        driver.cancelCurrentInteraction()
        driver.cancelCurrentInteraction()
        coordinator.cancel()
        XCTAssertEqual(choices, [.install, .skip])
    }


    private func updateState(_ stage: SPUUserUpdateStage) throws -> SPUUserUpdateState {
        let encoder = NSKeyedArchiver(requiringSecureCoding: true)
        encoder.encode(stage.rawValue, forKey: "SPUUserUpdateStateStage")
        encoder.encode(false, forKey: "SPUUserUpdateStateUserInitiated")
        encoder.finishEncoding()
        let decoder = try NSKeyedUnarchiver(forReadingFrom: encoder.encodedData)
        defer { decoder.finishDecoding() }
        return try XCTUnwrap(SPUUserUpdateState(coder: decoder))
    }

    func testNativeFoundAutomaticallyDownloadsAndResumesExtractionWithoutInstallationCommit() async throws {
        let item = try XCTUnwrap(SUAppcastItem(dictionary: [
            "title": "更新", "sparkle:version": "999", "sparkle:shortVersionString": "1.1.0",
            "enclosure": ["url": target.artifactURL.absoluteString, "length": "1234", "type": "application/octet-stream"]
        ]))
        for stage in [SPUUserUpdateStage.notDownloaded, .downloaded] {
            let driver = MacUpdateUserDriver(hostBundle: .main, delegate: nil)
            var choices: [SPUUserUpdateChoice] = []
            var verified = 0
            driver.allowsSession = { true }
            driver.verifyDownload = { verified += 1 }
            driver.prepareInstallation = { _, _ in XCTFail("下载和解压阶段不得提前提交安装") }
            driver.showUpdateFound(with: item, state: try updateState(stage), reply: { choices.append($0) })
            await until { choices == [.install] }
            XCTAssertEqual(verified, 1)
            driver.cancelCurrentInteraction()
            XCTAssertEqual(choices, [.install])
        }
    }

    func testTerminationRetryCanArriveBeforeNativeCallbackAndRevocationCancelsCommittedInstaller() async {
        let driver = MacUpdateUserDriver(hostBundle: .main, delegate: nil)
        let coordinator = MacIdleInstallationCoordinator()
        var idle = true
        var revoked = false
        var choices: [SPUUserUpdateChoice] = []
        var failures = 0
        var retried = 0
        driver.allowsSession = { true }
        coordinator.isIdle = { idle }
        coordinator.onFailure = { _ in failures += 1 }
        driver.prepareInstallation = { install, cancel in
            coordinator.submit(verify: { if revoked { throw MacManagementError.releaseWithdrawn } },
                               install: install, cancel: cancel, startTimer: false)
        }
        driver.showReady(toInstallAndRelaunch: { choices.append($0) })
        await until { choices == [.install] }
        idle = false
        driver.retryTerminationWhenIdle()
        driver.showInstallingUpdate(withApplicationTerminated: false, retryTerminatingApplication: { retried += 1 })
        await Task.yield()
        XCTAssertEqual(retried, 0)
        revoked = true
        idle = true
        coordinator.tick()
        await until { failures == 1 }
        XCTAssertEqual(choices, [.install, .skip])
        XCTAssertEqual(retried, 0)
        driver.cancelCurrentInteraction()
        XCTAssertEqual(choices.count, 2)
    }

    func testHeartbeatChangesCoalesceWhilePreviousRequestIsInFlight() async {
        let pump = MacHeartbeatPump()
        var continuation: CheckedContinuation<Void, Error>?
        var calls = 0
        pump.start(debounce: .zero, operation: {
            calls += 1
            if calls == 1 { try await withCheckedThrowingContinuation { continuation = $0 } }
        }, onError: { _ in XCTFail("回报不应失败") })
        defer { pump.stop() }
        await until { continuation != nil }
        for _ in 0..<20 { pump.request() }
        XCTAssertEqual(calls, 1)
        continuation?.resume()
        await until { calls == 2 }
        XCTAssertEqual(calls, 2)
    }
}
