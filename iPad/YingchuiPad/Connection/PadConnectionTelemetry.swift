import Observation

/// 高频统计只通知实际读取它们的组件，避免每秒重建整个视频界面。
@MainActor @Observable
final class PadConnectionTelemetry {
    var roundTripMilliseconds: Double?
    var roundTripP95Milliseconds: Double?
    var controlRoundTripMilliseconds: Double?
    var controlRoundTripP95Milliseconds: Double?
    var interactionToVideoFrameMilliseconds: Double?
    var interactionToVideoFrameP95Milliseconds: Double?
    var estimatedVideoLatencyMilliseconds: Double?
    var videoLatencyP50Milliseconds: Double?
    var videoLatencyP95Milliseconds: Double?
    var videoPacketsReceived: UInt64 = 0
    var videoFramesDecoded: UInt64 = 0
    var videoFramesDropped: UInt64 = 0
}

@MainActor
extension PadConnectionModel {
    var roundTripMilliseconds: Double? {
        get { telemetry.roundTripMilliseconds }
        set { telemetry.roundTripMilliseconds = newValue }
    }
    var roundTripP95Milliseconds: Double? {
        get { telemetry.roundTripP95Milliseconds }
        set { telemetry.roundTripP95Milliseconds = newValue }
    }
    var controlRoundTripMilliseconds: Double? {
        get { telemetry.controlRoundTripMilliseconds }
        set { telemetry.controlRoundTripMilliseconds = newValue }
    }
    var controlRoundTripP95Milliseconds: Double? {
        get { telemetry.controlRoundTripP95Milliseconds }
        set { telemetry.controlRoundTripP95Milliseconds = newValue }
    }
    var interactionToVideoFrameMilliseconds: Double? {
        get { telemetry.interactionToVideoFrameMilliseconds }
        set { telemetry.interactionToVideoFrameMilliseconds = newValue }
    }
    var interactionToVideoFrameP95Milliseconds: Double? {
        get { telemetry.interactionToVideoFrameP95Milliseconds }
        set { telemetry.interactionToVideoFrameP95Milliseconds = newValue }
    }
    var videoPacketsReceived: UInt64 {
        get { telemetry.videoPacketsReceived }
        set { telemetry.videoPacketsReceived = newValue }
    }
    var videoFramesDecoded: UInt64 {
        get { telemetry.videoFramesDecoded }
        set { telemetry.videoFramesDecoded = newValue }
    }
    var videoFramesDropped: UInt64 {
        get { telemetry.videoFramesDropped }
        set { telemetry.videoFramesDropped = newValue }
    }
    var estimatedVideoLatencyMilliseconds: Double? {
        get { telemetry.estimatedVideoLatencyMilliseconds }
        set { telemetry.estimatedVideoLatencyMilliseconds = newValue }
    }
    var videoLatencyP50Milliseconds: Double? {
        get { telemetry.videoLatencyP50Milliseconds }
        set { telemetry.videoLatencyP50Milliseconds = newValue }
    }
    var videoLatencyP95Milliseconds: Double? {
        get { telemetry.videoLatencyP95Milliseconds }
        set { telemetry.videoLatencyP95Milliseconds = newValue }
    }
}
