import Network

/// 发现、控制和音视频均允许系统建立点对点链路，不限定普通无线网卡或默认路由。
public enum PeerNetworkTransport {
    public static func discovery() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        return parameters
    }

    public static func control(tls: NWProtocolTLS.Options, includePeerToPeer: Bool = true) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        // 鼠标与按键都是短消息，不等待其他数据凑包。
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = includePeerToPeer
        parameters.serviceClass = .responsiveData
        return parameters
    }

    public static func video(host: NWEndpoint.Host? = nil) -> NWParameters {
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        parameters.serviceClass = .interactiveVideo
        parameters.requiredInterface = host?.interface
        return parameters
    }

    public static func audio(host: NWEndpoint.Host? = nil) -> NWParameters {
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        parameters.serviceClass = .interactiveVoice
        parameters.requiredInterface = host?.interface
        return parameters
    }

    /// 重连重新解析服务，不能固定在发现时的旧网卡；显式地址的作用域保持不变。
    public static func reconnectEndpoint(_ endpoint: NWEndpoint) -> NWEndpoint {
        guard case let .service(name, type, domain, _) = endpoint else { return endpoint }
        return .service(name: name, type: type, domain: domain, interface: nil)
    }

    /// 音视频沿已建立控制连接的真实地址发送，链路本地地址必须带接口作用域。
    public static func mediaHost(remoteEndpoint: NWEndpoint?) -> NWEndpoint.Host? {
        guard case let .hostPort(host, _) = remoteEndpoint else { return nil }
        switch host {
        case .ipv4: return host
        case .ipv6(let address):
            return address.isLinkLocal && address.interface == nil ? nil : host
        case .name: return nil
        @unknown default: return nil
        }
    }

    public static func routeDescription(_ path: NWPath) -> String {
        let medium = path.usesInterfaceType(.wifi) ? "无线" :
            (path.usesInterfaceType(.wiredEthernet) ? "有线" : "本地连接")
        let interfaces = Set(path.availableInterfaces.map(\.name)).sorted().joined(separator: "、")
        return "\(medium)，接口 \(interfaces)，远端 \(String(describing: path.remoteEndpoint))"
    }
}
