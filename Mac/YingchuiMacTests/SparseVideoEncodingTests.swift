import CoreVideo
import Foundation
import VideoToolbox
import XCTest
import YingchuiProtocol
@testable import YingchuiMac

final class SparseVideoEncodingTests: XCTestCase {
    func testSingleFrameLeavesEncoderWithoutWaitingForFutureFrames() async throws {
        try await verifySingleFrame(codec: .h264)
    }

    func testSingleHEVCFrameLeavesHardwareEncoderWithoutFutureFrames() async throws {
        guard MacVideoCodecSupport.canEncodeHEVC(StreamDimensions(width: 64, height: 64)) else {
            throw XCTSkip("当前硬件不提供 HEVC 编码")
        }
        try await verifySingleFrame(codec: .hevc)
    }

    private func verifySingleFrame(codec: VideoCodec) async throws {
        let streamer = MacScreenStreamer()
        defer { streamer.captureQueue.sync { streamer.stopOnCaptureQueue() } }
        try streamer.captureQueue.sync {
            streamer.outputWidth = 64
            streamer.outputHeight = 64
            streamer.videoCodec = codec
            try streamer.createCompressionSession()
            var pixelBuffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64,
                kCVPixelFormatType_32BGRA, nil, &pixelBuffer), kCVReturnSuccess)
            let pixels = try XCTUnwrap(pixelBuffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            if let address = CVPixelBufferGetBaseAddress(pixels) {
                memset(address, 0, CVPixelBufferGetDataSize(pixels))
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            streamer.encodeCapturedImage(pixels, forceKeyFrame: true)
        }
        // 不补交下一帧，不调用 CompleteFrames 强制冲刷；实际生产回调必须自行返回。
        let deadline = ContinuousClock.now + .seconds(2)
        while streamer.captureQueue.sync(execute: { streamer.videoProgress.encoded }) == 0,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(streamer.captureQueue.sync { streamer.videoProgress.encoded }, 1)
        let oldGeneration = UUID()
        let before = streamer.captureQueue.sync { streamer.framesDropped }
        streamer.captureQueue.sync {
            streamer.handleCompressionCallbackFailure(status: -1, generation: oldGeneration)
        }
        XCTAssertEqual(streamer.captureQueue.sync { streamer.framesDropped }, before)
        streamer.captureQueue.sync {
            streamer.handleEncoderDroppedFrame(generation: oldGeneration)
            XCTAssertEqual(streamer.videoProgress.encoderDropped, 0)
            streamer.forceNextKeyFrame = false
            streamer.handleEncoderDroppedFrame(generation: streamer.captureGeneration)
            XCTAssertEqual(streamer.videoProgress.encoderDropped, 1)
            XCTAssertFalse(streamer.forceNextKeyFrame, "编码器内部舍弃输入帧不应制造额外的关键帧突发")
        }
    }
}
