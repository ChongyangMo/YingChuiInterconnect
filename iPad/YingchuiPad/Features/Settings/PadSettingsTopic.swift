import Foundation

enum PadSettingsTopic: String, Identifiable {
    case controlMode, developerMode, networkRTT, networkP95, controlLatency, controlP95
    case inputFrame, inputFrameP95, captureLatency, captureP95, receivedDecoded, droppedFrames
    case ping, keyframe, diagnostics

    var id: String { rawValue }
    var title: String {
        switch self {
        case .controlMode: "操作方式"
        case .developerMode: "开发者模式"
        case .networkRTT: "网络 RTT"
        case .networkP95: "网络 P95"
        case .controlLatency: "控制执行"
        case .controlP95: "控制 P95"
        case .inputFrame: "输入至后续帧"
        case .inputFrameP95: "输入帧 P95"
        case .captureLatency: "采集至接收"
        case .captureP95: "采集接收 P95"
        case .receivedDecoded: "接收 / 解码"
        case .droppedFrames: "丢帧"
        case .ping: "测试延迟"
        case .keyframe: "请求关键帧"
        case .diagnostics: "导出诊断"
        }
    }

    var explanation: String {
        switch self {
        case .controlMode:
            "触摸：点按点击，单指滑动滚动；长按约半秒后移动可拖拽、选择文字，不动可悬停，双指轻点右键。预览时双指缩放或移动画面。鼠标键盘：单指移动指针，长按后拖动，双指滚动。"
        case .developerMode:
            "显示连接延迟、视频统计和排查工具。日常使用无需开启，打开也不会提升画质或速度。"
        case .networkRTT:
            "iPad 发出一次请求，到收到 Mac 回复所用的往返时间。数值越低，网络响应越快；不包含视频显示耗时。ms 表示毫秒，1000 毫秒等于 1 秒。"
        case .networkP95:
            "最近网络往返耗时中，约 95% 不超过这个值。它能帮助观察偶发的延迟，比单次读数更能反映网络是否稳定。"
        case .controlLatency:
            "从 iPad 发出操作，到 Mac 执行并回复确认的时间。不代表画面已经显示了这次操作的结果。"
        case .controlP95:
            "最近控制操作中，约 95% 的执行确认耗时不超过这个值。数值偏高时，部分操作可能有明显迟滞。"
        case .inputFrame:
            "从发出操作，到收到并处理操作之后采集的视频帧的估算时间。用于观察响应速度，不保证该帧已经包含操作产生的画面变化。"
        case .inputFrameP95:
            "最近输入到后续视频帧的估算耗时中，约 95% 不超过这个值。可用来观察偶发卡顿。"
        case .captureLatency:
            "视频帧从 Mac 采集到 iPad 收到的估算耗时，包含编码和网络传输。它依赖双端时钟校准，不包含最后显示到屏幕上的全部时间。"
        case .captureP95:
            "最近视频帧从采集到接收的估算耗时中，约 95% 不超过这个值。数值波动较大时，视频到达可能不够稳定。"
        case .receivedDecoded:
            "左侧是收到的视频数据包数，右侧是成功解码的视频帧数。一帧通常拆成多个数据包传输，因此两个数字不会相等。"
        case .droppedFrames:
            "未能按时完整组装或解码的视频帧数量。少量丢帧可能被自动恢复，持续增加时可能出现卡顿或画面缺失。"
        case .ping:
            "立即向 Mac 发出一次测试请求，测量网络往返耗时。不会改变当前投屏设置。"
        case .keyframe:
            "关键帧包含一幅可独立解码的完整画面。画面异常时，请求新关键帧可帮助恢复；正常播放时系统会自动处理，无需经常点击。"
        case .diagnostics:
            "生成连接状态和运行统计，便于排查问题。分享前可先查看内容，并选择要发送到的位置。"
        }
    }
}
