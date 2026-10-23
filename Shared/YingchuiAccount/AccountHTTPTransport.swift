import Foundation
import CFNetwork

protocol AccountHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

final class AccountURLSessionTransport: AccountHTTPTransport {
    private let session: URLSession

    init(useSystemProxy: Bool = true) {
        let configuration = URLSessionConfiguration.ephemeral
        if !useSystemProxy {
            // 仅按账号配置直连业务服务；不修改系统代理，也不在失败后切换线路。
            configuration.connectionProxyDictionary = [
                "HTTPEnable": 0,
                "HTTPSEnable": 0,
                "SOCKSEnable": 0,
                "ProxyAutoConfigEnable": 0,
                "ProxyAutoDiscoveryEnable": 0
            ]
        }
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        session = URLSession(configuration: configuration, delegate: AccountRedirectPolicy(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count <= 1_048_576 else {
            throw AccountError.invalidResponse
        }
        return (data, http)
    }

}

private final class AccountRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // 凭据请求不跟随重定向；保留系统默认 TLS 证书验证。
        completionHandler(nil)
    }
}
