/// 短时无线突发可以暂存，正常播放仍以低延迟为目标；持续积压必须在有限容量内报错。
public enum AudioBufferingPolicy {
    public static let recoveryThresholdMilliseconds = 500
    public static let maximumBufferedMilliseconds = 2_000
    public static let maximumBufferedFrames = AudioPacketCodec.sampleRate * maximumBufferedMilliseconds / 1_000
    public static let settledMilliseconds = 80
}
