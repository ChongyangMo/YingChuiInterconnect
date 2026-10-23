import Foundation
import Network

/// 只转发不透明 TLS 字节；证书固定、配对、鉴权仍由原控制通道执行。
public final class USBControlRelay: @unchecked Sendable {
    public var onReady: (@Sendable (NWConnection) -> Void)?
    private let local: NWConnection
    private let channel: USBPacketChannel
    private let queue: DispatchQueue
    private var closed = false
    private var writingBytes = 0

    public init(local: NWConnection, channel: USBPacketChannel, queue: DispatchQueue) {
        self.local = local; self.channel = channel; self.queue = queue
    }
    public func start() {
        local.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.onReady?(self.local); self.receive()
            case .failed, .cancelled: self.close(); self.channel.close()
            default: break
            }
        }
        local.start(queue: queue)
    }
    public func write(_ data: Data) {
        guard !closed else { return }
        guard writingBytes + data.count <= 262_144 else { close(); channel.close(); return }
        writingBytes += data.count
        local.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            self.writingBytes -= data.count
            if error != nil { self.close(); self.channel.close() }
        })
    }
    public func close() {
        guard !closed else { return }
        closed = true
        local.stateUpdateHandler = nil; local.cancel()
    }
    private func receive() {
        guard !closed else { return }
        local.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.channel.send(.control, payload: data) { [weak self] failure in
                    guard let self else { return }
                    self.queue.async { [weak self] in
                        guard let self, !self.closed else { return }
                        if done || error != nil || failure != nil { self.close(); self.channel.close() }
                        else { self.receive() }
                    }
                }
            } else if done || error != nil { self.close(); self.channel.close() }
            else { self.receive() }
        }
    }
}
