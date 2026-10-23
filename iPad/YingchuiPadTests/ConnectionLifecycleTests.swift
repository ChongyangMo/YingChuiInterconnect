import Combine
import Network
import XCTest
import YingchuiProtocol
@testable import YingchuiPad

final class ConnectionLifecycleTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testTransportLossClearsPlayingStateButPreservesRecoveryIntent() async {
        let model = PadConnectionModel(startServices: false)
        let connection = NWConnection(host: .ipv4(.loopback), port: 9, using: .tcp)
        model.connection = connection
        model.wantsStreaming = true
        model.isStreaming = true
        model.videoIsPlaying = true
        model.isConnected = true
        model.activeStreamID = UUID()
        model.handleConnectionClosed(connection, reason: "实际控制连接已断开")
        await drain(model)
        XCTAssertFalse(model.videoIsPlaying, "新流首帧完成前不能沿用旧流的播放就绪状态")
        XCTAssertFalse(model.isConnected)
        XCTAssertFalse(model.isStreaming)
        XCTAssertTrue(model.wantsStreaming)
        XCTAssertNil(model.activeStreamID)
    }

    private func drain(_ model: PadConnectionModel) async {
        await withCheckedContinuation { continuation in
            model.networkQueue.async {
                Task { @MainActor in continuation.resume() }
            }
        }
    }

    private func configuration(id: UUID) throws -> WireMessage {
        let fixture = try encodedFixture()
        return WireMessage(id: id, kind: .videoConfig, streamID: UUID(), codec: "h264",
            width: 64, height: 64, frameRate: 60, bitRate: 1_000_000,
            parameterSets: fixture.sets.map { $0.base64EncodedString() },
            displayState: RemoteDisplayState(mode: .standalone),
            videoKey: VideoDatagramCrypto.makeKey().base64EncodedString())
    }

    @MainActor
    func testStopRejectsConfigurationAlreadyQueuedForUI() async throws {
        let model = PadConnectionModel(startServices: false)
        let message = try configuration(id: UUID())
        model.wantsStreaming = true
        model.videoRequestID.set(message.id)
        model.videoConfigurationPending = true
        model.requestedVideoCapabilities.set([VideoDecodeCapability(codec: .h264)])
        model.requestedDisplayConfiguration = model.streamRequest
        model.handleVideoConfiguration(message)
        model.stopStreaming()
        await drain(model)
        XCTAssertFalse(model.isStreaming)
        XCTAssertNil(model.activeStreamID)
        XCTAssertNil(model.videoAspectRatio)
    }

    @MainActor
    func testRapidRestartAcceptsOnlyLatestConfiguration() async throws {
        let model = PadConnectionModel(startServices: false)
        let old = try configuration(id: UUID())
        let current = try configuration(id: UUID())
        model.wantsStreaming = true
        model.videoRequestID.set(current.id)
        model.videoConfigurationPending = true
        model.requestedVideoCapabilities.set([VideoDecodeCapability(codec: .h264)])
        model.requestedDisplayConfiguration = model.streamRequest
        model.handleVideoConfiguration(old)
        XCTAssertNil(model.activeStreamID)
        XCTAssertTrue(model.videoConfigurationPending)
        model.handleVideoConfiguration(current)
        await drain(model)
        XCTAssertTrue(model.isStreaming)
        XCTAssertEqual(model.activeStreamID, current.streamID)
        model.stopStreaming()
        await drain(model)
    }

    @MainActor
    func testBackgroundRejectsLateConfigurationWhilePreservingResumeIntent() async throws {
        let model = PadConnectionModel(startServices: false)
        let message = try configuration(id: UUID())
        model.wantsStreaming = true
        model.videoRequestID.set(message.id)
        model.videoConfigurationPending = true
        model.requestedVideoCapabilities.set([VideoDecodeCapability(codec: .h264)])
        model.requestedDisplayConfiguration = model.streamRequest
        model.prepareForBackground()
        model.handleVideoConfiguration(message)
        await drain(model)
        XCTAssertTrue(model.wantsStreaming)
        XCTAssertFalse(model.isStreaming)
        XCTAssertNil(model.activeStreamID)
    }

    @MainActor
    func testHostIdentityFailureDoesNotPoisonOtherHosts() async {
        let model = PadConnectionModel(startServices: false)
        model.failTrust("当前 Mac 身份校验失败")
        await drain(model)
        XCTAssertNil(model.credentialStoreErrorText)
        model.connectedHostKey = UUID().uuidString
        await withCheckedContinuation { continuation in
            model.networkQueue.async {
                model.connectOnNetworkQueue(to: .hostPort(host: .ipv4(.loopback), port: 9))
                XCTAssertNotNil(model.connection)
                XCTAssertEqual(model.connectionPhase, .connecting)
                model.disconnectOnNetworkQueue()
                continuation.resume()
            }
        }
    }

    @MainActor
    func testStorageFailureStillBlocksNewConnections() async {
        let model = PadConnectionModel(startServices: false)
        model.failTrust("凭据存储损坏", storageFailure: true)
        await drain(model)
        model.connectOnNetworkQueue(to: .hostPort(host: .ipv4(.loopback), port: 9))
        XCTAssertEqual(model.credentialStoreErrorText, "凭据存储损坏")
        XCTAssertNil(model.connection)
    }

    @MainActor
    func testVideoFailuresClearTransportAndRetryState() async {
        for code in ["screen_capture_permission_required", "invalid_stream_request",
                     "invalid_video_endpoint", "display_unavailable", "virtual_display_failed"] {
            let model = PadConnectionModel(startServices: false)
            let request = UUID()
            model.wantsStreaming = true
            model.isStreaming = true
            model.videoRequestID.set(request)
            model.activeStreamID = UUID()
            model.activeVideoPort = 1234
            model.videoAspectRatio = 1
            let retry = DispatchWorkItem {}
            let reconfigure = DispatchWorkItem {}
            model.streamRecoveryWorkItem = retry
            model.streamReconfigureWorkItem = reconfigure
            model.handleError(code, errorMessage: nil, requestID: request)
            await drain(model)
            XCTAssertFalse(model.isStreaming, code)
            XCTAssertFalse(model.wantsStreaming, code)
            XCTAssertNil(model.activeStreamID, code)
            XCTAssertNil(model.activeVideoPort, code)
            XCTAssertNil(model.videoRequestID.value, code)
            XCTAssertNil(model.videoAspectRatio, code)
            XCTAssertNil(model.streamRecoveryWorkItem, code)
            XCTAssertNil(model.streamReconfigureWorkItem, code)
            XCTAssertTrue(retry.isCancelled, code)
            XCTAssertTrue(reconfigure.isCancelled, code)
        }
    }

    @MainActor
    func testOldVideoErrorCannotStopNewRequest() async {
        let model = PadConnectionModel(startServices: false)
        let current = UUID()
        model.wantsStreaming = true
        model.isStreaming = true
        model.videoRequestID.set(current)
        model.handleError("display_unavailable", errorMessage: nil, requestID: UUID())
        await drain(model)
        XCTAssertTrue(model.isStreaming)
        XCTAssertTrue(model.wantsStreaming)
        XCTAssertEqual(model.videoRequestID.value, current)
        model.stopStreaming()
        await drain(model)
    }

    @MainActor
    func testEveryConnectionDeadlineDisconnectsWithoutAutomaticRetry() async {
        for phase in [PadConnectionPhase.connecting, .identifying, .pairing] {
            let model = PadConnectionModel(startServices: false)
            let connection = NWConnection(host: .ipv4(.loopback), port: 9, using: .tcp)
            model.connection = connection
            model.desiredEndpoint = connection.endpoint
            model.isConnected = true
            model.isPairing = true
            model.armConnectionDeadline(phase, on: connection)
            model.expireConnectionDeadline(phase, on: connection, epoch: model.connectionEpoch.value)
            await drain(model)
            XCTAssertNil(model.connection)
            XCTAssertNil(model.connectionDeadlineWorkItem)
            XCTAssertNil(model.reconnectWorkItem)
            XCTAssertFalse(model.isConnected)
            XCTAssertFalse(model.isPairing)
            XCTAssertEqual(model.statusText, phase.failureMessage)
        }
    }

    @MainActor
    func testPreviousPhaseAndOldConnectionDeadlinesCannotCloseCurrentConnection() async {
        let model = PadConnectionModel(startServices: false)
        let connection = NWConnection(host: .ipv4(.loopback), port: 9, using: .tcp)
        model.connection = connection
        let epoch = model.connectionEpoch.value
        model.armConnectionDeadline(.identifying, on: connection)
        model.expireConnectionDeadline(.connecting, on: connection, epoch: epoch)
        XCTAssertTrue(model.connection === connection)
        model.expireConnectionDeadline(.identifying, on: connection, epoch: UUID())
        XCTAssertTrue(model.connection === connection)
        model.disconnectOnNetworkQueue()
        await drain(model)
    }

    @MainActor
    func testDiscoveryFailureHasDedicatedVisibleState() async {
        let model = PadConnectionModel(startServices: false)
        model.statusText = "控制通道已就绪"
        model.publishDiscoveryStatus("等待局域网权限")
        await drain(model)
        XCTAssertEqual(model.discoveryStatus, "等待局域网权限")
        XCTAssertEqual(model.statusText, "控制通道已就绪")
    }

    @MainActor
    func testStaleHelloUIUpdateCannotOverwriteAnotherHost() async {
        let model = PadConnectionModel(startServices: false)
        let helloID = UUID()
        let oldHost = UUID().uuidString
        model.connectedHostKey = oldHost
        model.pendingHelloID = helloID
        model.handleHello(WireMessage(id: helloID, kind: .hello, deviceName: "旧 Mac", hostID: oldHost, accepted: false))
        model.connectionEpoch.set(UUID())
        model.connectedHostName = "新 Mac"
        await drain(model)
        XCTAssertEqual(model.connectedHostName, "新 Mac")
    }
}

extension ConnectionLifecycleTests {
    @MainActor
    func testSilentTLSPeerTriggersScheduledConnectionTimeout() async throws {
        let model = PadConnectionModel(startServices: false)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "ConnectionLifecycleTests.silent-peer")
        let peers = SynchronizedValue<[NWConnection]>([])
        let ready = expectation(description: "无响应测试服务已启动")
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.newConnectionHandler = { peer in
            peers.mutate { $0.append(peer) }
            peer.start(queue: queue)
        }
        listener.start(queue: queue)
        defer { listener.cancel(); peers.value.forEach { $0.cancel() } }
        await fulfillment(of: [ready], timeout: 5)
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: try XCTUnwrap(listener.port))
        let timedOut = expectation(description: "连接阶段定时器实际触发")
        let subscription = model.$statusText.sink { status in
            if status == PadConnectionPhase.connecting.failureMessage { timedOut.fulfill() }
        }
        defer { subscription.cancel() }
        model.connectedHostKey = UUID().uuidString
        model.networkQueue.async { model.connectOnNetworkQueue(to: endpoint) }
        await fulfillment(of: [timedOut], timeout: 14)
        XCTAssertNil(model.connection)
        XCTAssertNil(model.reconnectWorkItem)
    }

    @MainActor
    func testOldReceiverPortCannotStartNewStream() async {
        let model = PadConnectionModel(startServices: false)
        model.wantsStreaming = true
        model.connection = NWConnection(host: .ipv4(.loopback), port: 9, using: .tcp)
        model.videoReceiverGeneration.set(UUID())
        model.videoReceiver.onReady?(1234, UUID())
        await drain(model)
        XCTAssertNil(model.activeVideoPort)
        XCTAssertNil(model.videoRequestID.value)
        model.disconnectOnNetworkQueue()
        await drain(model)
    }

    @MainActor
    func testImmediateDisconnectAndNewSelectionDoesNotDropNewConnection() async {
        let model = PadConnectionModel(startServices: false)
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: 9)
        let host = DiscoveredHost(endpoint: endpoint, name: "新 Mac", hostID: UUID().uuidString)
        model.networkQueue.suspend()
        model.disconnect()
        model.connect(to: host)
        // 在同一批用户操作后，新的连接请求必须仍被执行。
        let observed = expectation(description: "新的主机选择被处理")
        model.networkQueue.async {
            XCTAssertEqual(model.desiredEndpoint, endpoint)
            observed.fulfill()
            model.desiredEndpoint = nil
            model.disconnectOnNetworkQueue()
        }
        model.networkQueue.resume()
        await fulfillment(of: [observed], timeout: 5)
        XCTAssertEqual(model.connectedHostName, "新 Mac")
    }
}

extension ConnectionLifecycleTests {
    @MainActor
    func testLockScreenReleasesConnectionAndPreservesEndpointWithoutBackgroundRetries() async {
        let model = PadConnectionModel(startServices: false)
        let connection = NWConnection(host: .ipv4(.loopback), port: 9, using: .tcp)
        model.connection = connection
        model.desiredEndpoint = connection.endpoint
        model.wantsStreaming = true
        model.isConnected = true
        model.isPaired = true
        model.activeStreamID = UUID()
        let retry = DispatchWorkItem {}
        model.reconnectWorkItem = retry
        model.prepareForBackground()
        await drain(model)
        XCTAssertTrue(model.isInBackgroundState.value)
        XCTAssertNil(model.connection)
        XCTAssertNil(model.activeStreamID)
        XCTAssertNotNil(model.desiredEndpoint)
        XCTAssertTrue(model.wantsStreaming)
        XCTAssertFalse(model.isConnected)
        XCTAssertFalse(model.isPaired)
        XCTAssertTrue(retry.isCancelled)
        await withCheckedContinuation { continuation in
            model.networkQueue.async {
                model.scheduleReconnectIfNeeded()
                model.connectOnNetworkQueue(to: connection.endpoint)
                XCTAssertNil(model.reconnectWorkItem)
                XCTAssertNil(model.connection)
                continuation.resume()
            }
        }
    }
}
