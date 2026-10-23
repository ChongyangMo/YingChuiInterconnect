import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import XCTest
@testable import YingchuiMac

final class ContinuousVideoEncodingTests: XCTestCase {
    func testContinuousDesktopAvoidsPeriodicKeyBurstsAndStillHonorsRecovery() throws {
        let output = ContinuousEncodedFrames()
        var created: VTCompressionSession?
        XCTAssertEqual(VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: 320, height: 240,
            codecType: kCMVideoCodecType_H264, encoderSpecification: [
                kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
            ] as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: { context, _, status, flags, sample in
                guard let context else { return }
                Unmanaged<ContinuousEncodedFrames>.fromOpaque(context).takeUnretainedValue()
                    .append(status: status, dropped: flags.contains(.frameDropped), sample: sample)
            }, refcon: Unmanaged.passUnretained(output).toOpaque(), compressionSessionOut: &created), noErr)
        let session = try XCTUnwrap(created)
        defer { VTCompressionSessionInvalidate(session) }
        let streamer = MacScreenStreamer()
        streamer.outputBitRate = 4_000_000
        streamer.outputFrameRate = 60
        try streamer.configureCompressionSession(session)
        XCTAssertEqual(VTCompressionSessionPrepareToEncodeFrames(session), noErr)
        var createdImage: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &createdImage), kCVReturnSuccess)
        let image = try XCTUnwrap(createdImage)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(image, []), kCVReturnSuccess)
        memset(try XCTUnwrap(CVPixelBufferGetBaseAddress(image)), 128, CVPixelBufferGetDataSize(image))
        XCTAssertEqual(CVPixelBufferUnlockBaseAddress(image, []), kCVReturnSuccess)
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<300 {
            let properties: CFDictionary? = index == 270
                ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            XCTAssertEqual(VTCompressionSessionEncodeFrame(session, imageBuffer: image,
                presentationTimeStamp: CMTime(value: Int64(index), timescale: 60),
                duration: CMTime(value: 1, timescale: 60), frameProperties: properties,
                sourceFrameRefcon: nil, infoFlagsOut: nil), noErr)
            let deadline = start + UInt64(index + 1) * 16_666_667
            let now = DispatchTime.now().uptimeNanoseconds
            if deadline > now { Thread.sleep(forTimeInterval: Double(deadline - now) / 1_000_000_000) }
        }
        XCTAssertEqual(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid), noErr)
        let result = output.snapshot()
        XCTAssertEqual(result.errors, 0)
        XCTAssertEqual(result.dropped, 0)
        XCTAssertEqual(result.frames, 300)
        XCTAssertEqual(result.keyFrameIndices, [0, 270], "连续桌面不能每两秒产生整帧突发，接收端恢复请求必须仍然生效")
        print("连续编码实测：300 帧，关键帧位置 \(result.keyFrameIndices)，编码错误 \(result.errors)")
    }
}

private final class ContinuousEncodedFrames: @unchecked Sendable {
    struct Snapshot { var frames = 0; var errors = 0; var dropped = 0; var keyFrameIndices: [Int] = [] }
    private let lock = NSLock()
    private var result = Snapshot()
    func append(status: OSStatus, dropped: Bool, sample: CMSampleBuffer?) {
        lock.lock(); defer { lock.unlock() }
        if status != noErr { result.errors += 1 }
        if dropped { result.dropped += 1 }
        guard let sample else { return }
        result.frames += 1
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        if !notSync { result.keyFrameIndices.append(Int((sample.presentationTimeStamp.seconds * 60).rounded())) }
    }
    func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return result }
}
