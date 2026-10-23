import Foundation

public enum VideoStreamLimits {
    public static let minimumFrameRate = 15
    public static let maximumFrameRate = 120
    public static let minimumBitRate = 1_000_000
    public static let maximumBitRate = 60_000_000

    public static func normalizedFrameRate(_ value: Int) -> Int {
        max(minimumFrameRate, min(maximumFrameRate, value))
    }

    public static func normalizedBitRate(_ value: Int) -> Int {
        max(minimumBitRate, min(maximumBitRate, value))
    }
}
