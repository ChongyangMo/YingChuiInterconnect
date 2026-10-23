import CoreMedia

enum MacCaptureCadencePolicy {
    static func minimumInterval(frameRate: Int, displayRefreshRate: Double) -> CMTime {
        precondition(frameRate > 0)
        // 显示器本身已限定刷新率时，避免采集器再加一层定时节流产生拍频。
        // 高刷新率显示器仍按客户端请求限制采集，未知刷新率也保留显式限制。
        if displayRefreshRate.isFinite, displayRefreshRate > 0,
           displayRefreshRate <= Double(frameRate) + 0.5 { return .zero }
        return CMTime(value: 1, timescale: CMTimeScale(frameRate))
    }
}
