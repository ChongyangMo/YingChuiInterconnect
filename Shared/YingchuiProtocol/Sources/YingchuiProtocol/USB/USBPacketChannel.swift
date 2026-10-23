import Foundation
import Network

public typealias USBMediaPacketSink = @Sendable (USBPacketKind, Data, @escaping @Sendable (NWError?) -> Void) -> Void

/// 有界的可靠字节流适配；控制、声音优先，视频内部仍保持顺序。
public final class USBPacketChannel: @unchecked Sendable {
    public var onPacket: (@Sendable (USBPacket) -> Void)?
    public var onClosed: (@Sendable (String) -> Void)?
    private struct Pending {
        let packet: USBPacket
        let data: Data
        let at: UInt64
        let completion: @Sendable (NWError?) -> Void
    }
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var decoder = USBPacketDecoder()
    private var pending: [Pending] = []
    private var pendingBytes = 0
    private var sending = false
    private var sendingAt: UInt64?
    private var closed = false
    private var watchdog: DispatchSourceTimer?

    public init(connection: NWConnection, queue: DispatchQueue) { self.connection = connection; self.queue = queue }
    public func start(alreadyStarted: Bool = false) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now()+1, repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self, let oldest = ([self.pending.first?.at, self.sendingAt].compactMap { $0 }).min(),
                  DispatchTime.now().uptimeNanoseconds - oldest > 500_000_000 else { return }
            self.closeOnQueue("USB 发送等待超过半秒，关闭通道并重新连接")
        }
        watchdog = timer; timer.resume()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: if !alreadyStarted { self.receive() }
            case .failed(let error): self.closeOnQueue("USB 通道失败：\(error.localizedDescription)")
            case .cancelled: self.closeOnQueue("USB 通道已断开")
            default: break
            }
        }
        if alreadyStarted { receive() } else { connection.start(queue: queue) }
    }
    public func send(_ kind: USBPacketKind, payload: Data, completion: @escaping @Sendable (NWError?) -> Void = { _ in }) {
        queue.async { [weak self] in
            guard let self, !self.closed else { completion(.posix(.ECONNABORTED)); return }
            do {
                let packet = USBPacket(kind: kind, payload: payload), data = try USBPacketCodec.encode(USBPacket(kind: kind, payload: payload))
                guard self.pendingBytes + data.count <= 2_097_152 else { throw USBPacketError.bufferFull }
                self.pendingBytes += data.count
                self.pending.append(Pending(packet: packet, data: data, at: DispatchTime.now().uptimeNanoseconds, completion: completion))
                self.drain()
            } catch {
                completion(.posix(.ENOBUFS))
                self.closeOnQueue(error.localizedDescription)
            }
        }
    }
    public func close() { queue.async { [weak self] in self?.closeOnQueue("USB 通道已关闭") } }
    private func drain() {
        guard !sending, !pending.isEmpty, !closed else { return }
        let index = pending.firstIndex(where: { $0.packet.kind == .control || $0.packet.kind == .introduction })
            ?? pending.firstIndex(where: { $0.packet.kind == .audio }) ?? 0
        let item = pending.remove(at: index)
        sending = true
        sendingAt = item.at
        connection.send(content: item.data, completion: .contentProcessed { [weak self] error in
            guard let self else { item.completion(.posix(.ECONNABORTED)); return }
            guard !self.closed else { item.completion(.posix(.ECONNABORTED)); return }
            self.pendingBytes -= item.data.count; self.sending = false; self.sendingAt = nil
            item.completion(error)
            if let error { self.closeOnQueue("USB 数据发送失败：\(error.localizedDescription)") }
            else { self.drain() }
        })
    }
    private func receive() {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            do {
                if let data { for packet in try self.decoder.append(data) { self.onPacket?(packet) } }
                if let error { self.closeOnQueue("USB 数据接收失败：\(error.localizedDescription)"); return }
                if done { self.closeOnQueue("USB 对端已关闭连接"); return }
                self.receive()
            } catch { self.closeOnQueue(error.localizedDescription) }
        }
    }
    private func closeOnQueue(_ reason: String) {
        guard !closed else { return }
        closed = true; watchdog?.cancel(); watchdog = nil
        connection.stateUpdateHandler = nil; connection.cancel()
        let queued = pending; pending.removeAll(); pendingBytes = 0
        queued.forEach { $0.completion(.posix(.ECONNABORTED)) }
        onClosed?(reason)
    }
}
