import Foundation

struct AccountConfiguration: Decodable {
    static var defaultClientID: String {
#if os(iOS)
        "com.yingchui.interconnect.pad"
#else
        "com.yingchui.interconnect.mac"
#endif
    }

    let baseURL: URL
    let clientID: String
    let contractVersion: String
    let appleEnabled: Bool
    let useSystemProxy: Bool

    init(baseURL: URL, clientID: String, contractVersion: String, appleEnabled: Bool = false,
         useSystemProxy: Bool = true) {
        self.baseURL = baseURL
        self.clientID = clientID
        self.contractVersion = contractVersion
        self.appleEnabled = appleEnabled
        self.useSystemProxy = useSystemProxy
    }

    static func load(bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "AccountConfiguration", withExtension: "json") else {
            throw AccountError.invalidConfiguration
        }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try value.validate()
        return value
    }

    func validate() throws {
        guard baseURL.scheme == "https", baseURL.host == "chongyang.asia",
              baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil,
              baseURL.port == nil,
              ["", "/"].contains(baseURL.path),
              clientID == Self.defaultClientID,
              contractVersion == "auth-v1.0.0" else { throw AccountError.invalidConfiguration }
    }
}
