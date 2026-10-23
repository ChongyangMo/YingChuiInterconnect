import CryptoKit
import CoreMedia
import Foundation
import Network
import Security
import VideoToolbox

private final class TLSClient: @unchecked Sendable {
    let certificateFingerprint: String
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.yingchui.tools.tls-probe")

    init(port: UInt16) throws {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv13)
        let fingerprintLock = NSLock()
        var observedFingerprint: String?
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                  let certificate = chain.first else {
                complete(false)
                return
            }
            let data = SecCertificateCopyData(certificate) as Data
            let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            fingerprintLock.lock()
            observedFingerprint = fingerprint
            fingerprintLock.unlock()
            complete(true)
        }, queue)

        guard let networkPort = NWEndpoint.Port(rawValue: port) else { throw ProbeError.invalidPort }
        connection = NWConnection(
            host: .ipv4(.loopback),
            port: networkPort,
            using: NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        )
        let ready = DispatchSemaphore(value: 0)
        var stateError: Error?
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                stateError = error
                ready.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { throw ProbeError.timeout }
        if let stateError { throw stateError }
        fingerprintLock.lock()
        certificateFingerprint = observedFingerprint ?? ""
        fingerprintLock.unlock()
    }

    func send(
        kind: String,
        fields: [String: Any] = [:],
        version: Int = YingchuiService.protocolVersion
    ) throws -> [String: Any] {
        var message: [String: Any] = [
            "version": version,
            "id": UUID().uuidString,
            "kind": kind,
            "sentAtMilliseconds": UInt64(Date().timeIntervalSince1970 * 1_000)
        ]
        for (key, value) in fields { message[key] = value }
        let payload = try JSONSerialization.data(withJSONObject: message)
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)

        let sent = DispatchSemaphore(value: 0)
        var sendError: NWError?
        connection.send(content: frame, completion: .contentProcessed { error in
            sendError = error
            sent.signal()
        })
        guard sent.wait(timeout: .now() + 3) == .success else { throw ProbeError.timeout }
        if let sendError { throw sendError }

        let header = try receive(count: 4)
        let payloadLength = header.reduce(0) { ($0 << 8) | Int($1) }
        let response = try receive(count: payloadLength)
        guard let dictionary = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw ProbeError.invalidResponse
        }
        if version == YingchuiService.protocolVersion,
           ["hello", "pairRequest", "streamStart"].contains(kind) {
            try require(dictionary["id"] as? String == message["id"] as? String, "响应未绑定当前请求")
        }
        return dictionary
    }

    func sendDeclaredFrameLength(_ length: UInt32) throws {
        var bigEndianLength = length.bigEndian
        let data = Data(bytes: &bigEndianLength, count: MemoryLayout<UInt32>.size)
        let sent = DispatchSemaphore(value: 0)
        var sendError: NWError?
        connection.send(content: data, completion: .contentProcessed { error in
            sendError = error
            sent.signal()
        })
        guard sent.wait(timeout: .now() + 3) == .success else { throw ProbeError.timeout }
        if let sendError { throw sendError }
    }

    func waitForPeerClosure(timeout: DispatchTimeInterval = .seconds(3)) -> Bool {
        let finished = DispatchSemaphore(value: 0)
        var didClose = false
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, complete, error in
            didClose = complete || error != nil
            finished.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else { return false }
        return didClose
    }

    func close() {
        connection.cancel()
    }

    private func receive(count: Int) throws -> Data {
        let received = DispatchSemaphore(value: 0)
        var result = Data()
        var receiveError: Error?
        func next() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: count - result.count) { data, _, complete, error in
                if let data { result.append(data) }
                if let error { receiveError = error }
                if result.count == count || complete || error != nil {
                    received.signal()
                } else {
                    next()
                }
            }
        }
        next()
        guard received.wait(timeout: .now() + 10) == .success else { throw ProbeError.timeout }
        if let receiveError { throw receiveError }
        guard result.count == count else { throw ProbeError.invalidResponse }
        return result
    }
}

private final class UDPCollector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.yingchui.tools.udp-probe")
    private let listener: NWListener
    private var connection: NWConnection?
    private let received = DispatchSemaphore(value: 0)
    private var reassembler = VideoFrameReassembler()
    private(set) var completedFrame: CompletedVideoFrame?
    private var videoKey: Data?
    private var packetCount = 0
    private var frameCount = 0
    private var authenticationFailures = 0
    private var missingFrames: UInt64 = 0
    private var lastFrameID: UInt32?
    private(set) var port: UInt16 = 0

    init() throws {
        listener = try NWListener(using: .udp)
        let ready = DispatchSemaphore(value: 0)
        var resolvedPort: UInt16?
        listener.stateUpdateHandler = { [weak listener] state in
            if case .ready = state {
                resolvedPort = listener?.port?.rawValue
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connection = connection
            connection.start(queue: self.queue)
            self.receiveNext(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, let resolvedPort else { throw ProbeError.timeout }
        port = resolvedPort
    }

    func waitForFrame() -> CompletedVideoFrame? {
        received.wait(timeout: .now() + 8) == .success ? completedFrame : nil
    }

    func configure(videoKey: Data) {
        queue.sync {
            self.videoKey = videoKey
            self.reassembler.reset()
        }
    }

    func snapshot() -> (packets: Int, frames: Int, missing: UInt64, authenticationFailures: Int) {
        queue.sync { (packetCount, frameCount, missingFrames, authenticationFailures) }
    }

    func close() {
        connection?.cancel()
        listener.cancel()
    }

    private func receiveNext(_ activeConnection: NWConnection) {
        activeConnection.receiveMessage { [weak self, weak activeConnection] data, _, _, error in
            guard let self, let activeConnection, self.connection === activeConnection else { return }
            if let data, let videoKey = self.videoKey {
                self.packetCount += 1
                do {
                    let plaintext = try VideoDatagramCrypto.open(data, key: videoKey)
                    let fragment = try VideoDatagramCodec.decode(plaintext)
                    if let frame = self.reassembler.append(fragment) {
                        if let lastFrameID {
                            guard Int32(bitPattern: frame.frameID &- lastFrameID) > 0 else {
                                self.receiveNext(activeConnection)
                                return
                            }
                            let distance = frame.frameID &- lastFrameID
                            if distance > 1 {
                                self.missingFrames += UInt64(distance - 1)
                            }
                        }
                        self.lastFrameID = frame.frameID
                        self.frameCount += 1
                        if self.completedFrame == nil {
                            self.completedFrame = frame
                            self.received.signal()
                        }
                    }
                } catch {
                    self.authenticationFailures += 1
                }
            }
            if error == nil {
                self.receiveNext(activeConnection)
            }
        }
    }
}

private final class DecodeResult: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    var succeeded = false
}

private enum H264DecodeProbe {
    static func decode(accessUnit: Data, parameterSets: [Data]) throws -> Bool {
        guard parameterSets.count >= 2 else { throw ProbeError.assertion("missing H.264 parameter sets") }
        var formatDescription: CMFormatDescription?
        let formatStatus = parameterSets[0].withUnsafeBytes { spsBytes in
            parameterSets[1].withUnsafeBytes { ppsBytes in
                guard let sps = spsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let pps = ppsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return OSStatus(-1) }
                var pointers: [UnsafePointer<UInt8>] = [sps, pps]
                var sizes = [parameterSets[0].count, parameterSets[1].count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDescription
                )
            }
        }
        guard formatStatus == noErr, let formatDescription else {
            throw ProbeError.assertion("invalid H.264 format")
        }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: accessUnit.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: accessUnit.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else { throw ProbeError.assertion("block buffer failed") }
        status = accessUnit.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: accessUnit.count
            )
        }
        guard status == noErr else { throw ProbeError.assertion("block copy failed") }
        var sampleSize = accessUnit.count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { throw ProbeError.assertion("sample buffer failed") }

        let result = DecodeResult()
        var session: VTDecompressionSession?
        status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else { throw ProbeError.assertion("decoder creation failed") }
        defer { VTDecompressionSessionInvalidate(session) }
        status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback],
            infoFlagsOut: nil,
            completionHandler: { status, _, imageBuffer, _, _, _ in
                result.succeeded = status == noErr && imageBuffer != nil
                result.semaphore.signal()
            }
        )
        guard status == noErr else { throw ProbeError.assertion("decode submission failed") }
        return result.semaphore.wait(timeout: .now() + 5) == .success && result.succeeded
    }
}

private enum ProbeError: Error {
    case invalidPort
    case timeout
    case invalidResponse
    case assertion(String)
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ProbeError.assertion(message) }
}

guard CommandLine.arguments.count >= 2,
      let port = UInt16(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("用法：TLSProbe <端口> <六位配对码>\n".utf8))
    exit(2)
}
if CommandLine.arguments.contains("--handshake-only") {
    do {
        let client = try TLSClient(port: port)
        defer { client.close() }
        let hello = try client.send(kind: "hello", fields: [
            "deviceName": "连接验证探针", "deviceID": UUID().uuidString
        ])
        try require(hello["kind"] as? String == "hello", "身份确认响应类型无效")
        try require(hello["version"] as? Int == YingchuiService.protocolVersion, "主机协议版本不匹配")
        try require(hello["accepted"] as? Bool == false, "未配对探针不应被授权")
        print("TLS 握手、协议版本与身份响应编号验证通过")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("连接验证失败：\(error)\n".utf8))
        exit(1)
    }
}
guard CommandLine.arguments.count >= 3 else {
    FileHandle.standardError.write(Data("缺少六位配对码\n".utf8))
    exit(2)
}
let pairingCode = CommandLine.arguments[2]
guard pairingCode.count == 6, pairingCode.allSatisfy(\.isNumber) else {
    FileHandle.standardError.write(Data("配对码必须是六位数字\n".utf8))
    exit(2)
}

do {
    let deviceID = "yingchui-swift-tls-probe"
    let first = try TLSClient(port: port)
    let hello = try first.send(kind: "hello", fields: ["deviceName": "TLS Probe", "deviceID": deviceID])
    try require(hello["accepted"] as? Bool == false, "新设备不应自动受信任")
    guard let hostID = hello["hostID"] as? String,
          UUID(uuidString: hostID) != nil else {
        throw ProbeError.assertion("缺少稳定的 Mac 身份")
    }
    let pairing = try first.send(kind: "pairRequest", fields: ["deviceID": deviceID, "pairingCode": pairingCode])
    guard let token = pairing["sessionToken"] as? String else { throw ProbeError.assertion("缺少会话令牌") }
    try require(pairing["accepted"] as? Bool == true, "配对被拒绝")
    let fingerprint = first.certificateFingerprint
    first.close()

    let second = try TLSClient(port: port)
    let trusted = try second.send(kind: "hello", fields: ["deviceName": "TLS Probe", "deviceID": deviceID, "sessionToken": token])
    try require(trusted["accepted"] as? Bool == true, "有效令牌被拒绝")
    try require(trusted["hostID"] as? String == hostID, "Mac 身份发生变化")
    try require(second.certificateFingerprint == fingerprint, "证书发生变化")

    if CommandLine.arguments.contains("--stream") {
        let udp = try UDPCollector()
        let response = try second.send(kind: "streamStart", fields: [
            "audioEnabled": false, "videoPort": Int(udp.port), "width": 1280, "height": 720,
            "viewportWidth": 1280, "viewportHeight": 720,
            "frameRate": 30, "bitRate": 4_000_000
        ])
        if response["kind"] as? String == "videoConfig" {
            guard let encodedVideoKey = response["videoKey"] as? String,
                  let videoKey = Data(base64Encoded: encodedVideoKey) else {
                throw ProbeError.assertion("缺少 UDP 视频密钥")
            }
            udp.configure(videoKey: videoKey)
            guard let frame = udp.waitForFrame() else { throw ProbeError.assertion("未收到完整的加密 UDP 视频帧") }
            let parameterSets = (response["parameterSets"] as? [String] ?? []).compactMap { Data(base64Encoded: $0) }
            let decoded = try H264DecodeProbe.decode(accessUnit: frame.accessUnit, parameterSets: parameterSets)
            try require(decoded, "H.264 解码失败")
            print("屏幕采集、加密传输与硬件解码通过（\(frame.accessUnit.count) 字节）")
            if let optionIndex = CommandLine.arguments.firstIndex(of: "--soak-seconds"),
               CommandLine.arguments.indices.contains(optionIndex + 1),
               let seconds = UInt32(CommandLine.arguments[optionIndex + 1]) {
                let deadline = ProcessInfo.processInfo.systemUptime + Double(seconds)
                while ProcessInfo.processInfo.systemUptime < deadline {
                    let heartbeat = try second.send(kind: "ping")
                    try require(heartbeat["kind"] as? String == "pong", "持续运行心跳响应无效")
                    Thread.sleep(forTimeInterval: min(1, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
                }
                let snapshot = udp.snapshot()
                try require(snapshot.frames >= Int(seconds) * 20, "视频帧率低于持续运行阈值")
                try require(snapshot.authenticationFailures == 0, "持续运行期间出现 UDP 认证失败")
                print("\(seconds) 秒视频持续运行通过（\(snapshot.frames) 帧，\(snapshot.packets) 包，缺失 \(snapshot.missing) 帧）")
            }
        } else {
            try require(response["detail"] as? String == "screen_capture_permission_required", "屏幕回传响应不符合预期")
            print("屏幕录制权限门禁通过")
        }
        udp.close()
    }
    second.close()

    let third = try TLSClient(port: port)
    let rejected = try third.send(kind: "hello", fields: ["deviceName": "TLS Probe", "deviceID": deviceID, "sessionToken": "tampered"])
    try require(rejected["accepted"] as? Bool == false, "篡改后的令牌不应被接受")
    third.close()

    if CommandLine.arguments.contains("--negative") {
        let unauthorized = try TLSClient(port: port)
        let unauthorizedStream = try unauthorized.send(kind: "streamStart", fields: ["videoPort": 45_000])
        try require(unauthorizedStream["kind"] as? String == "error", "未授权回传没有返回错误")
        try require(unauthorizedStream["detail"] as? String == "pairing_required", "未授权回传没有被拒绝")
        unauthorized.close()

        let incompatible = try TLSClient(port: port)
        let versionError = try incompatible.send(kind: "hello", version: 999)
        try require(versionError["kind"] as? String == "error", "不兼容协议版本没有返回错误")
        try require(versionError["detail"] as? String == "unsupported_protocol_version", "协议错误详情不正确")
        incompatible.close()

        let oversized = try TLSClient(port: port)
        try oversized.sendDeclaredFrameLength(UInt32(YingchuiService.maximumFrameSize + 1))
        try require(oversized.waitForPeerClosure(), "超长消息没有关闭连接")
        oversized.close()

        for index in 0..<25 {
            let client = try TLSClient(port: port)
            let response = try client.send(
                kind: "hello",
                fields: ["deviceName": "Reconnect Probe \(index)", "deviceID": "reconnect-probe-\(index)"]
            )
            try require(response["accepted"] as? Bool == false, "新的重连探针不应自动受信任")
            client.close()
        }
        print("未授权回传拒绝通过")
        print("不兼容协议版本拒绝通过")
        print("超长消息拒绝通过")
        print("25 次 TLS 重连压力检查通过")
    }

    print("TLS 1.3 握手通过")
    print("证书稳定性通过（\(fingerprint.prefix(16))…）")
    print("256 位令牌重连通过")
    print("篡改令牌拒绝通过")
} catch {
    FileHandle.standardError.write(Data("TLS 探针失败：\(error)\n".utf8))
    exit(1)
}
