import AVFoundation
import CoreMedia
import Network
import YingchuiProtocol

/// 由屏幕采集队列串行调用，声音通过当前媒体通道发送。
final class MacAudioSender: @unchecked Sendable {
    private var connection: NWConnection?
    private var packetSink: USBMediaPacketSink?
    // 与 start / stop 一样，仅由采集队列读取。
    var transportState: NWConnection.State? { packetSink != nil ? .ready : connection?.state }
    private var streamID = UUID()
    private var key = Data()
    private var sequence: UInt32 = 0
    private let budget = MacAudioSendBudget()
    private let log = DiagnosticEventLog(subsystem: "com.yingchui.interconnect.mac", category: "声音发送")
    private var isReportingBacklog = false
    private let completionQueue = DispatchQueue(label: "com.yingchui.mac.audio-send", qos: .userInteractive)
    private var onFailure: ((String) -> Void)?

    func start(host: NWEndpoint.Host, port: NWEndpoint.Port, streamID: UUID, key: Data,
               queue: DispatchQueue, packetSink: USBMediaPacketSink? = nil, onFailure: @escaping (String) -> Void) {
        stop()
        self.streamID = streamID; self.key = key; self.onFailure = onFailure
        self.packetSink = packetSink
        failureQueue = queue
        if packetSink != nil { return }
        let generation = budget.generation
        let parameters = PeerNetworkTransport.audio(host: host)
        let connection = NWConnection(host: host, port: port, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.reportFailure("声音连接失败：\(error.localizedDescription)", generation: generation, on: queue)
            }
        }
        connection.start(queue: completionQueue)
        failureQueue = queue
    }

    func send(_ sample: CMSampleBuffer) throws {
        guard connection != nil || packetSink != nil, let description = sample.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd), format.sampleRate == 48_000,
              format.channelCount == 2 else { throw AudioPacketError.unsupportedFormat }
        let frames = sample.numSamples
        guard frames > 0, frames <= 48_000,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw AudioPacketError.invalidPacket
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { throw AudioPacketError.unsupportedFormat }
        let pcm = try Self.interleavedPCM(buffer)
        var datagrams: [(data: Data, frames: Int)] = []
        for offset in stride(from: 0, to: frames, by: AudioPacketCodec.maximumFrames) {
            let end = min(frames, offset + AudioPacketCodec.maximumFrames)
            let packet = AudioPacket(streamID: streamID, sequence: sequence, pcm: pcm.subdata(in: offset * 4..<end * 4))
            let data = try VideoDatagramCrypto.seal(AudioPacketCodec.encode(packet), key: key)
            sequence &+= 1
            datagrams.append((data, end - offset))
        }
        // 编码成功后整批预留，避免编码异常留下无法归还的容量。
        let generation = try budget.reserve(frames: frames)
        let pendingMilliseconds = budget.pendingFrames * 1_000 / AudioPacketCodec.sampleRate
        if pendingMilliseconds > AudioBufferingPolicy.recoveryThresholdMilliseconds, !isReportingBacklog {
            isReportingBacklog = true
            log.record("声音发送暂时积压 \(pendingMilliseconds) 毫秒，等待传输通道发送完成")
        } else if pendingMilliseconds <= AudioBufferingPolicy.settledMilliseconds, isReportingBacklog {
            isReportingBacklog = false
            log.record("声音发送积压已恢复，当前 \(pendingMilliseconds) 毫秒")
        }
        let failureQueue = self.failureQueue
        if let packetSink {
            for datagram in datagrams {
                packetSink(.audio, datagram.data) { [weak self] error in
                    guard let self, self.budget.complete(frames: datagram.frames, generation: generation) else { return }
                    if let error { self.reportFailure("USB 声音发送失败：\(error.localizedDescription)", generation: generation, on: failureQueue) }
                }
            }
            return
        }
        guard let connection else { throw AudioPacketError.invalidPacket }
        connection.batch {
            for datagram in datagrams {
                connection.send(content: datagram.data, completion: .contentProcessed { [weak self] error in
                    guard let self, self.budget.complete(frames: datagram.frames, generation: generation) else { return }
                    if let error {
                        self.reportFailure("声音发送失败：\(error.localizedDescription)", generation: generation, on: failureQueue)
                    }
                })
            }
        }
    }

    static func interleavedPCM(_ buffer: AVAudioPCMBuffer) throws -> Data {
        let format = buffer.format
        guard format.sampleRate == 48_000, format.channelCount == 2 else { throw AudioPacketError.unsupportedFormat }
        var bytes = Data(count: Int(buffer.frameLength) * 4)
        try bytes.withUnsafeMutableBytes { destination in
            for frame in 0..<Int(buffer.frameLength) {
                for channel in 0..<2 {
                    let index = format.isInterleaved ? frame * 2 + channel : frame
                    let plane = format.isInterleaved ? 0 : channel
                    let sample: Int16
                    if let floats = buffer.floatChannelData {
                        let value = floats[plane][index]
                        guard value.isFinite else { throw AudioPacketError.unsupportedFormat }
                        sample = Int16((max(-1, min(1, value)) * 32_767).rounded())
                    } else if let integers = buffer.int16ChannelData { sample = integers[plane][index] }
                    else { throw AudioPacketError.unsupportedFormat }
                    destination.storeBytes(of: sample.littleEndian, toByteOffset: (frame * 2 + channel) * 2, as: Int16.self)
                }
            }
        }
        return bytes
    }

    func stop() {
        budget.reset()
        isReportingBacklog = false
        connection?.stateUpdateHandler = nil
        connection?.cancel(); connection = nil
        packetSink = nil
        key = Data(); sequence = 0; onFailure = nil
    }

    private var failureQueue = DispatchQueue(label: "com.yingchui.mac.audio-failure")

    private func reportFailure(_ message: String, generation: UUID, on queue: DispatchQueue) {
        guard budget.fail(generation) else { return }
        queue.async { [weak self] in
            guard let self, self.budget.isFailed(generation) else { return }
            self.onFailure?(message)
        }
    }
}
