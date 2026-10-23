import CoreVideo
import Foundation
import YingchuiProtocol

/// 仅在诊断启动时抽样已有采集帧的亮度，不保存图像，也不改变画面发送。
struct MacStartupImageProbe {
    private var samples = 0
    private var finished = false
    private let enabled = ProcessInfo.processInfo.arguments.contains("--diagnostic-console")
        || ProcessInfo.processInfo.arguments.contains("--physical-smoke-test")

    mutating func inspect(_ image: CVPixelBuffer, trace: StreamStartupTrace?) {
        guard enabled, !finished, samples < 600 else { return }
        samples += 1
        guard CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else {
            trace?.mark("采集亮度诊断不可用", detail: "像素格式不支持")
            finished = true
            return
        }
        let status = CVPixelBufferLockBaseAddress(image, .readOnly)
        guard status == kCVReturnSuccess else {
            trace?.mark("采集亮度诊断失败", detail: "像素缓冲区锁定错误 \(status)")
            finished = true
            return
        }
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(image, 0) else {
            trace?.mark("采集亮度诊断失败", detail: "缺少亮度平面")
            finished = true
            return
        }
        let width = CVPixelBufferGetWidthOfPlane(image, 0)
        let height = CVPixelBufferGetHeightOfPlane(image, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var low: UInt8 = 255
        var high: UInt8 = 0
        for y in 0..<16 {
            for x in 0..<16 {
                let value = pixels[(y * height / 16) * stride + x * width / 16]
                low = min(low, value)
                high = max(high, value)
            }
        }
        let detail = "亮度抽样范围 \(low)–\(high)，采集样本 \(samples)"
        if samples == 1 { trace?.mark("首帧采集亮度", detail: detail) }
        if high > 32 && Int(high) - Int(low) > 16 {
            trace?.mark("首个有亮度层次的采集帧", detail: detail)
            finished = true
        } else if samples == 600 {
            trace?.mark("采集亮度诊断结束", detail: detail)
        }
    }
}
