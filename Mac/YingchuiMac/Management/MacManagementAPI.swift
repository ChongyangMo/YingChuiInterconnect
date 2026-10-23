import Foundation

protocol MacManagementService: Sendable {
    func status() async throws -> MacManagementStatus
    func heartbeat(_ payload: MacHeartbeat, token: String) async throws -> MacHeartbeatReceipt
}

struct MacManagementAPI: MacManagementService {
    private struct Failure: Decodable {
        struct Detail: Decodable { let code: String }
        let error: Detail
    }
    let configuration: MacManagementConfiguration
    let transport: any AccountHTTPTransport

    init(configuration: MacManagementConfiguration, transport: (any AccountHTTPTransport)? = nil) throws {
        try configuration.validate()
        self.configuration = configuration
        self.transport = transport ?? AccountURLSessionTransport(useSystemProxy: configuration.useSystemProxy)
    }

    func status() async throws -> MacManagementStatus {
        let value: MacManagementStatus = try await request("status")
        guard value.contract_version == configuration.contractVersion else { throw MacManagementError.response }
        return value
    }

    func heartbeat(_ payload: MacHeartbeat, token: String) async throws -> MacHeartbeatReceipt {
        guard !token.isEmpty, !token.contains("\r"), !token.contains("\n") else { throw MacManagementError.unauthorized }
        let value: MacHeartbeatReceipt = try await request("heartbeat", body: JSONEncoder().encode(payload), token: token)
        try value.validate()
        return value
    }

    private func request<T: Decodable>(_ path: String, body: Data? = nil, token: String? = nil) async throws -> T {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("api/yingchui/v1/mac/\(path)"))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("com.yingchui.interconnect.mac", forHTTPHeaderField: "X-Client-ID")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await transport.send(request)
        try Task.checkCancellation()
        switch response.statusCode {
        case 200: break
        case 404, 503: throw MacManagementError.unavailable
        case 401, 403: throw MacManagementError.unauthorized
        case 409:
            guard data.count <= 65_536, response.mimeType == "application/json" else { throw MacManagementError.response }
            let failure: Failure
            do { failure = try JSONDecoder().decode(Failure.self, from: data) }
            catch { throw MacManagementError.response }
            if failure.error.code == "invalid_update_job" { throw MacManagementError.invalidUpdateJob }
            throw MacManagementError.http(409)
        default: throw MacManagementError.http(response.statusCode)
        }
        guard response.mimeType == "application/json", data.count <= 65_536 else { throw MacManagementError.response }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw MacManagementError.response }
    }
}
