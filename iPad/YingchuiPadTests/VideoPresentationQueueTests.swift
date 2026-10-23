import AVFoundation
import XCTest
@testable import YingchuiPad
@testable import YingchuiProtocol

final class VideoPresentationQueueTests: XCTestCase {
    @MainActor
    func testInteractionWarmsClockWithoutDisplayingAnInventedFrame() async {
        let queue = PadVideoPresentationQueue()
        var displays = 0, didTick = false
        let warmed = expectation(description: "输入发生时提前唤醒真实显示时钟")
        queue.onDisplay = { _, _ in displays += 1; return true }
        queue.onClockGap = { _ in
            if !didTick { didTick = true; warmed.fulfill() }
        }
        queue.prepareForInteraction()
        await fulfillment(of: [warmed], timeout: 2)
        XCTAssertEqual(displays, 0)
        queue.reset()
    }

    @MainActor
    func testEmptyQueueKeepsClockWarmThenSleepsWithoutInventingFrames() async throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let image = try XCTUnwrap(buffer), stream = UUID()
        let queue = PadVideoPresentationQueue()
        var shown: [UInt32] = [], ticks = 0, observedWarmTick = false
        let warmClock = expectation(description: "队列暂空后仍保持刷新节奏")
        queue.onDisplay = { _, frame in shown.append(frame.frameID); return true }
        queue.onClockGap = { _ in
            ticks += 1
            if shown == [0, 1], !observedWarmTick {
                observedWarmTick = true
                warmClock.fulfill()
            }
        }
        for id: UInt32 in [0, 1] {
            queue.submit(image, frame: CompletedVideoFrame(streamID: stream, frameID: id,
                presentationTimeMicroseconds: UInt64(id), isKeyFrame: id == 0, accessUnit: Data()))
        }
        await fulfillment(of: [warmClock], timeout: 2)
        try await Task.sleep(for: .milliseconds(650))
        let idleTicks = ticks
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(ticks, idleTicks)
        XCTAssertEqual(shown, [0, 1])
        queue.reset()
    }

    @MainActor
    func testBurstKeepsNewestDecodedImageAndResetRejectsOldDelivery() async throws {
        var createdImage: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &createdImage), kCVReturnSuccess)
        let image = try XCTUnwrap(createdImage), stream = UUID()
        func frame(_ id: UInt32) -> CompletedVideoFrame {
            CompletedVideoFrame(streamID: stream, frameID: id, presentationTimeMicroseconds: UInt64(id), isKeyFrame: id == 0, accessUnit: Data())
        }
        let queue = PadVideoPresentationQueue()
        var shown: [UInt32] = [], coalesced = 0
        let delivered = expectation(description: "交付最新解码图像")
        queue.onDisplay = { _, frame in
            shown.append(frame.frameID)
            if frame.frameID == 4 { delivered.fulfill() }
            return true
        }
        queue.onCoalesced = { _ in coalesced += 1 }
        queue.submit(image, frame: frame(0))
        queue.submit(image, frame: frame(1))
        queue.submit(image, frame: frame(2))
        queue.submit(image, frame: frame(3))
        queue.submit(image, frame: frame(4))
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(shown, [0,2,3,4]); XCTAssertEqual(coalesced, 1)
        queue.submit(image, frame: frame(5))
        queue.reset()
        queue.submit(image, frame: frame(6))
        let drained = expectation(description: "旧会话显示任务已经退出")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertEqual(shown, [0,2,3,4,6])
    }
}
