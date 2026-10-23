import CoreMedia
import CoreVideo
import VideoToolbox
import XCTest
@testable import YingchuiMac

final class StaticQualityRecoveryTests: XCTestCase {
    func testStaticTextRefinesBeforeOneSecondAtWirelessBitRate() throws {
        let baseline = try measure(refine: false)
        let improved = try measure(refine: true)
        print("静止画质实测：旧策略结束后 350 毫秒误差 \(baseline.error)，当前策略 \(improved.error)，旧输出 \(baseline.frames) 帧，当前输出 \(improved.frames) 帧")
        XCTAssertGreaterThan(improved.frames, baseline.frames, "动画结束后应继续发送短暂的真实静止画面来恢复细节")
        XCTAssertLessThan(improved.error, baseline.error * 0.8, "同一码率下，动画收尾 350 毫秒内的画质应明显改善")
    }

    func testWirelessStartRateKeepsMotionAndTailFramesContinuous() throws {
        let value = try measure(refine: true, bitRate: 12_000_000)
        XCTAssertEqual(value.frames, 70, "60 帧每秒动画及静止细节收敛输入应完整输出")
        XCTAssertEqual(value.dropped, 0)
        XCTAssertLessThan(value.error, 5, "收尾文字细节不能因保持帧率而明显模糊")
        print("无线起始码率编码实测：70 个输入，输出 \(value.frames)，丢弃 \(value.dropped)，收尾误差 \(value.error)")
    }

    private func measure(refine: Bool, bitRate: Int = 4_000_000) throws -> (error: Double, frames: Int, dropped: Int) {
        let width = 2224, height = 1668
        let results = QualityEncodedFrames()
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: [
                kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
            ] as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: { context, _, status, flags, sample in
                guard let context else { return }
                let results = Unmanaged<QualityEncodedFrames>.fromOpaque(context).takeUnretainedValue()
                results.append(status: status, sample: sample, dropped: flags.contains(.frameDropped))
            }, refcon: Unmanaged.passUnretained(results).toOpaque(), compressionSessionOut: &created)
        XCTAssertEqual(status, noErr)
        let session = try XCTUnwrap(created)
        defer { VTCompressionSessionInvalidate(session) }
        let streamer = MacScreenStreamer()
        streamer.outputBitRate = bitRate
        streamer.outputFrameRate = 60
        try streamer.configureCompressionSession(session)
        XCTAssertEqual(VTCompressionSessionPrepareToEncodeFrames(session), noErr)
        var policy = MacIdleFramePolicy()
        let finalImage = try makeTextPattern(width: width, height: height, offset: 0)
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<82 {
            let idle = index >= 60
            let now = UInt64(index) * 16_666_667
            let image: CVPixelBuffer
            if idle || index == 59 { image = finalImage }
            else { image = try shifted(finalImage, offset: (59 - index) * 11) }
            let encode = refine
                ? policy.shouldEncode(isIdle: idle, hasImage: true, forceKeyFrame: false, now: now)
                : !idle
            if encode {
                XCTAssertEqual(VTCompressionSessionEncodeFrame(session, imageBuffer: image,
                    presentationTimeStamp: CMTime(value: Int64(index), timescale: 60),
                    duration: CMTime(value: 1, timescale: 60), frameProperties: nil,
                    sourceFrameRefcon: nil, infoFlagsOut: nil), noErr)
            }
            let deadline = start + UInt64(index + 1) * 16_666_667
            let current = DispatchTime.now().uptimeNanoseconds
            if deadline > current { Thread.sleep(forTimeInterval: Double(deadline - current) / 1_000_000_000) }
        }
        XCTAssertEqual(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid), noErr)
        let samples = results.snapshot()
        XCTAssertTrue(samples.failures.isEmpty, "硬件编码不得报错")
        let decoded = try decodeLast(samples.frames)
        return (try lumaError(decoded, comparedWith: finalImage), samples.frames.count, samples.dropped)
    }

    private func shifted(_ source: CVPixelBuffer, offset: Int) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created), kCVReturnSuccess)
        let image = try XCTUnwrap(created)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(image, []), kCVReturnSuccess)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(source, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(image, []); CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        let a = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(image, 0))
        let b = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(source, 0))
        let aStride = CVPixelBufferGetBytesPerRowOfPlane(image, 0), bStride = CVPixelBufferGetBytesPerRowOfPlane(source, 0)
        let shift = offset % width
        for row in 0..<height {
            memcpy(a + row * aStride + shift, b + row * bStride, width - shift)
            memcpy(a + row * aStride, b + row * bStride + width - shift, shift)
        }
        let chroma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(image, 1))
        memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(image, 1) * CVPixelBufferGetHeightOfPlane(image, 1))
        return image
    }

    private func makeTextPattern(width: Int, height: Int, offset: Int) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created), kCVReturnSuccess)
        let image = try XCTUnwrap(created)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(image, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(image, []) }
        let y = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(image, 0)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        memset(y, 238, stride * height)
        let chroma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(image, 1))
        memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(image, 1) * CVPixelBufferGetHeightOfPlane(image, 1))
        // 确定性的细线、字符笔画和边缘，模拟侧栏与文字窗口移动后停下。
        for row in 0..<70 {
            for column in 0..<100 {
                let x = (column * 21 + offset) % (width - 20)
                let top = row * 22 + 30
                let bits = (row * 71 + column * 13) % 31 + 1
                for dy in 0..<13 {
                    for dx in 0..<11 where dx == 0 || dy == 0 || dy == 12 || (dx + dy + bits) % 5 == 0 {
                        y[(top + dy) * stride + x + dx] = UInt8(24 + bits)
                    }
                }
            }
        }
        return image
    }

    private func decodeLast(_ samples: [CMSampleBuffer]) throws -> CVPixelBuffer {
        let first = try XCTUnwrap(samples.first)
        var created: VTDecompressionSession?
        XCTAssertEqual(VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
            formatDescription: try XCTUnwrap(first.formatDescription), decoderSpecification: nil,
            imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &created), noErr)
        let session = try XCTUnwrap(created)
        defer { VTDecompressionSessionInvalidate(session) }
        let output = QualityDecodedImage()
        for sample in samples {
            XCTAssertEqual(VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
                status, _, image, _, _ in
                XCTAssertEqual(status, noErr)
                output.set(image)
            }, noErr)
        }
        XCTAssertEqual(VTDecompressionSessionWaitForAsynchronousFrames(session), noErr)
        return try XCTUnwrap(output.image)
    }

    private func lumaError(_ decoded: CVPixelBuffer, comparedWith source: CVPixelBuffer) throws -> Double {
        XCTAssertEqual(CVPixelBufferLockBaseAddress(decoded, .readOnly), kCVReturnSuccess)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(source, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(decoded, .readOnly); CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        let a = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(decoded, 0)).assumingMemoryBound(to: UInt8.self)
        let b = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(source, 0)).assumingMemoryBound(to: UInt8.self)
        let aStride = CVPixelBufferGetBytesPerRowOfPlane(decoded, 0), bStride = CVPixelBufferGetBytesPerRowOfPlane(source, 0)
        var error = 0.0, count = 0.0
        for y in stride(from: 30, to: 1560, by: 2) {
            for x in stride(from: 0, to: 2200, by: 2) {
                let difference = Double(a[y * aStride + x]) - Double(b[y * bStride + x])
                error += difference * difference
                count += 1
            }
        }
        return error / count
    }
}

private final class QualityEncodedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [CMSampleBuffer] = []
    private var failures: [OSStatus] = []
    private var droppedFrames = 0
    func append(status: OSStatus, sample: CMSampleBuffer?, dropped: Bool) {
        lock.lock(); defer { lock.unlock() }
        if status != noErr { failures.append(status) }
        if dropped { droppedFrames += 1 }
        if let sample { frames.append(sample) }
    }
    func snapshot() -> (frames: [CMSampleBuffer], failures: [OSStatus], dropped: Int) {
        lock.lock(); defer { lock.unlock() }; return (frames, failures, droppedFrames)
    }
}
private final class QualityDecodedImage: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CVPixelBuffer?
    var image: CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ value: CVPixelBuffer?) { lock.lock(); defer { lock.unlock() }; stored = value }
}
