import SwiftUI
import YingchuiProtocol

enum MacDashboardTopic {
    case port, connections, trusted, pairing, stream, accessibility, screenRecording, identity, service

    var title: String {
        switch self {
        case .port: "端口"
        case .connections: "连接"
        case .trusted: "可信设备"
        case .pairing: "首次配对"
        case .stream: "屏幕回传"
        case .accessibility: "辅助功能"
        case .screenRecording: "屏幕录制"
        case .identity: "重新配对"
        case .service: "连接服务"
        }
    }

    @MainActor
    func information(for host: MacHostModel) -> MacCardInfo {
        let message: String
        switch self {
        case .port:
            message = host.isRunning
                ? "当前端口为 \(host.portText)，用于 iPad 与 Mac 的配对和控制连接。iPad 会自动发现，无需手动设置；重启服务后端口可能变化。音视频使用单独的传输通道。"
                : "端口是 iPad 连接 Mac 服务的通信入口。服务启动后会自动分配，iPad 会自动发现，无需手动设置。"
        case .connections:
            message = "当前有 \(host.connectedClientCount) 个连接，可能包含等待配对的设备。连接数量不等于正在投屏的设备数量；同一时间只有一个 iPad 能控制 Mac。"
        case .trusted:
            message = "已授权 \(host.pairedDeviceCount) 台设备，下次连接无需重复输入配对码。可在设置的“可信设备”中查看或撤销授权。"
        case .pairing:
            message = "在 iPad 首次连接这台 Mac 时输入此六位码，确认连接授权。配对码有效期为 5 分钟，过期会自动更新；已配对的设备无需重复输入。"
        case .stream:
            message = "将 Mac 画面实时传到 iPad。复制模式显示相同画面，扩展模式增加桌面空间；未接显示器时使用独立虚拟桌面。在 iPad 开始回传并选择模式。"
        case .accessibility:
            message = "允许 iPad 的键鼠和触摸操作控制 Mac。" + (host.isAccessibilityGranted
                ? "当前已授权，右侧刷新可重新检查权限。"
                : "点击右侧授权，在系统设置中允许鹰锤互联控制电脑。")
        case .screenRecording:
            message = "用于读取 Mac 屏幕并实时传到 iPad。" + (host.isScreenCaptureGranted
                ? "当前已授权，右侧刷新可重新检查权限。"
                : "点击右侧授权，在系统设置中允许鹰锤互联录制屏幕。")
        case .identity:
            message = "这台 Mac 的安全连接身份已重新生成，iPad 保存的旧身份不再匹配。请在 iPad 重置这台 Mac 的信任并重新配对。"
        case .service:
            message = host.isRunning
                ? "连接服务正在运行，iPad 可以发现并连接这台 Mac。服务在线不代表已开始投屏；启停操作在设置中。"
                : "连接服务已停止，iPad 暂时无法连接。可在设置中启动服务。"
        }
        return MacCardInfo(title: title, message: message)
    }
}
