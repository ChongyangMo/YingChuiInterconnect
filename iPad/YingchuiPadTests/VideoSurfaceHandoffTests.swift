import AVFoundation
import UIKit
import XCTest
import YingchuiProtocol
@testable import YingchuiPad

final class VideoSurfaceHandoffTests: XCTestCase {
    @available(iOS 17.4, *)
    @MainActor
    func testNewSurfaceDisplaysLastRealFrameWithoutAnotherNetworkFrame() async throws {
        let renderer = VideoRenderer()
        let fixture = try encodedFixture()
        let stream = UUID()
        let decoded = expectation(description: "显示层创建前真实帧已解码")
        renderer.onFrameDecoded = { _ in decoded.fulfill() }
        renderer.onFailure = { XCTFail($0) }
        try renderer.configure(streamID: stream, parameterSets: fixture.sets)
        var reassembler = VideoFrameReassembler()
        var completed: CompletedVideoFrame?
        for packet in try VideoDatagramCodec.fragment(accessUnit: fixture.payload, streamID: stream,
            frameID: 0, presentationTimeMicroseconds: 0, isKeyFrame: true) {
            completed = reassembler.append(try VideoDatagramCodec.decode(packet)) ?? completed
        }
        try renderer.enqueue(XCTUnwrap(completed))
        await fulfillment(of: [decoded], timeout: 5)

        let layer = HandoffRecordingLayer()
        defer { renderer.reset() }
        renderer.attach(layer, videoGravity: .resizeAspect)
        XCTAssertEqual(layer.samples.value.count, 1,
                       "新显示层必须立即收到最近的真实解码帧，无需下一次网络更新")
        let sample = try XCTUnwrap(layer.samples.value.first?.value)
        let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        XCTAssertEqual(CVPixelBufferGetWidth(image), 64)
        XCTAssertEqual(CVPixelBufferGetHeight(image), 64)
        renderer.attach(layer, videoGravity: .resizeAspect)
        XCTAssertEqual(layer.samples.value.count, 1, "重复布局更新不能重复投递缓存帧")

        renderer.detach(layer)
        renderer.reset()
        let fresh = HandoffRecordingLayer()
        renderer.attach(fresh, videoGravity: .resizeAspect)
        XCTAssertTrue(fresh.samples.value.isEmpty, "停止回传后新显示层不得显示旧会话画面")

    }
}

private struct HandoffSample: @unchecked Sendable { let value: CMSampleBuffer }

private final class HandoffRecordingLayer: AVSampleBufferDisplayLayer, @unchecked Sendable {
    let samples = SynchronizedValue<[HandoffSample]>([])
    override func enqueue(_ sampleBuffer: CMSampleBuffer) {
        samples.mutate { $0.append(HandoffSample(value: sampleBuffer)) }
        super.enqueue(sampleBuffer)
    }
}
