import Foundation
import Network
import CoreGraphics
import YingchuiProtocol

final class HostPeerSession: @unchecked Sendable {
    let id = UUID()
    var deviceName = "iPad"
    var deviceID = ""
    var isAuthorized = false
    var isSuperseded = false
    var supportsAccountLink = false
    var accountLinkLease: AccountLinkLease?
    var streamRequestID: UUID?
    var streamID: UUID?
    var supportsCursor = false
    var cursorSendInFlight = false
    var pendingCursorState: RemoteCursorState?
    var lastCursorInputSequence: UInt64 = 0
    var statistics = StreamStatisticsTracker()
    var didReceiveHello = false
    var peerMinimumProtocolVersion: Int?
    var wireVersion = YingchuiService.protocolVersion
    var remoteButtonState = RemoteButtonState()
    var touchGestureID: UUID?
    var touchScrollEndEvent: CGEvent?
    var touchClickSequence = MacTouchClickSequence()

    private let connection: NWConnection
    private let onMessage: @Sendable (HostPeerSession, WireMessage) -> Void
    private let onClosed: @Sendable (HostPeerSession) -> Void
    private let onStatus: @Sendable (String) -> Void
    private var decoder = WireMessageDecoder()
    private var hasClosed = false
    private var timeoutTimer: DispatchSourceTimer?
    private var startedAt = ProcessInfo.processInfo.systemUptime
    private var lastActivityAt = ProcessInfo.processInfo.systemUptime
    private var isReady = false

    var remoteHost: NWEndpoint.Host? {
        PeerNetworkTransport.mediaHost(remoteEndpoint: connection.currentPath?.remoteEndpoint)
    }
    var remoteEndpoint: NWEndpoint? { connection.currentPath?.remoteEndpoint }

    init(
        connection: NWConnection,
        onMessage: @escaping @Sendable (HostPeerSession, WireMessage) -> Void,
        onClosed: @escaping @Sendable (HostPeerSession) -> Void,
        onStatus: @escaping @Sendable (String) -> Void
    ) {
        self.connection = connection
        self.onMessage = onMessage
        self.onClosed = onClosed
        self.onStatus = onStatus
    }

    func start(on queue: DispatchQueue) {
        startedAt = ProcessInfo.processInfo.systemUptime
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let expired = !self.isReady ? now - self.startedAt >= 10
                : (self.isAuthorized ? now - self.lastActivityAt >= 15 : now - self.startedAt >= 60)
            if expired {
                self.onStatus("客户端握手、配对或心跳超时，已断开连接")
                self.closeOnce()
            }
        }
        timeoutTimer = timer
        timer.resume()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.isReady = true
                if let path = self.connection.currentPath {
                    self.onStatus("客户端控制连接已建立：" + PeerNetworkTransport.routeDescription(path))
                }
                self.receiveNext()
            case .failed(let error):
                self.onStatus("客户端连接失败：\(error.localizedDescription)")
                self.closeOnce()
            case .cancelled:
                self.closeOnce()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ message: WireMessage, completion: (@Sendable () -> Void)? = nil) {
        do {
            var outgoing = message
            outgoing.version = wireVersion
            connection.send(content: try WireCodec.encode(outgoing), completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.onStatus("控制消息发送失败：\(error.localizedDescription)")
                    self?.connection.cancel()
                }
                completion?()
            })
        } catch {
            onStatus("控制消息编码失败：\(error.localizedDescription)")
            connection.cancel()
            completion?()
        }
    }

    func cancel() {
        timeoutTimer?.cancel()
        connection.cancel()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                do {
                    for message in try self.decoder.append(data) {
                        guard !self.hasClosed else { return }
                        self.lastActivityAt = ProcessInfo.processInfo.systemUptime
                        self.onMessage(self, message)
                    }
                } catch {
                    self.onStatus("客户端协议数据无效：\(error.localizedDescription)")
                    self.connection.cancel()
                    return
                }
            }

            if let error {
                self.onStatus("控制消息接收失败：\(error.localizedDescription)")
                self.closeOnce()
                return
            }
            if isComplete {
                self.closeOnce()
                return
            }
            self.receiveNext()
        }
    }

    private func closeOnce() {
        guard !hasClosed else { return }
        hasClosed = true
        timeoutTimer?.cancel()
        timeoutTimer = nil
        connection.cancel()
        onClosed(self)
    }
}
