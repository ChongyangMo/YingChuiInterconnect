import Foundation
import Network
import YingchuiProtocol

struct MacUSBDevice: Sendable { let id: Int; let serial: String }

enum MacUSBMuxClient {
    static func devices(queue: DispatchQueue) async throws -> [MacUSBDevice] {
        let connection = try await open(queue: queue)
        let pending = armTimeout(connection, queue: queue)
        defer { pending.set(false); connection.cancel() }
        try await request(["MessageType": "ListDevices"], connection: connection)
        let reply = try await response(connection)
        guard let devices = reply["DeviceList"] as? [[String: Any]] else { throw USBPacketError.invalidFrame }
        return devices.compactMap { entry in
            guard let properties = entry["Properties"] as? [String: Any],
                  properties["ConnectionType"] as? String == "USB",
                  let id = (properties["DeviceID"] ?? entry["DeviceID"]) as? Int,
                  let serial = properties["SerialNumber"] as? String else { return nil }
            return MacUSBDevice(id: id, serial: serial)
        }
    }
    static func connect(_ device: MacUSBDevice, port: UInt16, queue: DispatchQueue) async throws -> NWConnection {
        let connection = try await open(queue: queue)
        let pending = armTimeout(connection, queue: queue)
        defer { pending.set(false) }
        do {
            try await request(["MessageType": "Connect", "DeviceID": device.id, "PortNumber": Int(port.bigEndian)], connection: connection)
            let reply = try await response(connection)
            guard reply["MessageType"] as? String == "Result", reply["Number"] as? Int == 0 else {
                throw NWError.posix(.ECONNREFUSED)
            }
            connection.stateUpdateHandler = nil
            return connection
        } catch { connection.cancel(); throw error }
    }
    private static func open(queue: DispatchQueue) async throws -> NWConnection {
        let connection = NWConnection(to: .unix(path: "/var/run/usbmuxd"), using: .tcp)
        defer { connection.stateUpdateHandler = nil }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let finished = SynchronizedValue(false)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if finished.mutate({ value in guard !value else { return false }; value = true; return true }) { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    if finished.mutate({ value in guard !value else { return false }; value = true; return true }) {
                        connection.cancel(); continuation.resume(throwing: error)
                    }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now()+3) {
                if finished.mutate({ value in guard !value else { return false }; value = true; return true }) {
                    connection.cancel(); continuation.resume(throwing: NWError.posix(.ETIMEDOUT))
                }
            }
        }
        connection.stateUpdateHandler = nil
        return connection
    }
    private static func armTimeout(_ connection: NWConnection, queue: DispatchQueue) -> SynchronizedValue<Bool> {
        let pending = SynchronizedValue(true)
        queue.asyncAfter(deadline: .now()+5) { if pending.value { connection.cancel() } }
        return pending
    }
    private static func request(_ fields: [String: Any], connection: NWConnection) async throws {
        var fields = fields
        fields["ClientVersionString"] = "YingchuiInterconnect"
        fields["ProgName"] = "YingchuiInterconnect"
        fields["kLibUSBMuxVersion"] = 3
        let body = try PropertyListSerialization.data(fromPropertyList: fields, format: .xml, options: 0)
        var data = Data()
        for value in [UInt32(body.count+16), 1, 8, 1] {
            var word = value.littleEndian
            data.append(withUnsafeBytes(of: &word) { Data($0) })
        }
        data.append(body)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    private static func response(_ connection: NWConnection) async throws -> [String: Any] {
        let header = try await read(16, connection)
        let size = Int(header.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset*8) })
        guard size >= 16, size <= 1_048_576,
              header[4] == 1, header[8] == 8 else { throw USBPacketError.invalidFrame }
        let body = try await read(size-16, connection)
        guard let value = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] else { throw USBPacketError.invalidFrame }
        return value
    }
    private static func read(_ count: Int, _ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, data.count == count { continuation.resume(returning: data) }
                else { continuation.resume(throwing: USBPacketError.invalidFrame) }
            }
        }
    }
}
