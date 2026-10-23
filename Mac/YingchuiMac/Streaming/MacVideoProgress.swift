import Foundation

/// 仅在 captureQueue 上读写；在请求关键帧和停止时输出诊断，不按帧打印。
struct MacVideoProgress {
    var captureCallbacks: UInt64 = 0
    var submitted: UInt64 = 0
    var encoded: UInt64 = 0
    var encoderDropped: UInt64 = 0
    var lastKeyFrameDescription = "尚无关键帧"
    var lastCaptureUptime: UInt64?
    var lastEncodedUptime: UInt64?
    var captureStatus = "尚未收到采集帧"

    mutating func recordCapture(status: String, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        captureCallbacks &+= 1
        lastCaptureUptime = now
        captureStatus = status
    }

    mutating func recordEncoded(now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        encoded &+= 1
        lastEncodedUptime = now
    }

    func summary(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> String {
        func age(_ time: UInt64?) -> String {
            guard let time, now >= time else { return "尚无记录" }
            return "\((now - time) / 1_000_000) 毫秒前"
        }
        return "采集回调 \(captureCallbacks)，最近状态 \(captureStatus)，最近采集 \(age(lastCaptureUptime))，提交编码 \(submitted)，编码输出 \(encoded)，编码器丢帧 \(encoderDropped)，最近编码 \(age(lastEncodedUptime))，\(lastKeyFrameDescription)"
    }
}
