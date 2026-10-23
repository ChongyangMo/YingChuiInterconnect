import AVFoundation
import XCTest
@testable import YingchuiPad

final class VideoDisplayLatencyTests: XCTestCase {
    func testEveryDecodedFrameDisplaysImmediatelyIncludingBurstsAndClockJumps() throws {
        var created: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64,
            kCVPixelFormatType_32BGRA, nil, &created), kCVReturnSuccess)
        let image = try XCTUnwrap(created)
        for source: UInt64 in [0, 16_667, 33_334, 1_000_000, 1_016_667, 100] {
            let sample = try VideoDisplaySampleFactory.make(image: image, sourceMicroseconds: source)
            let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(sample,
                createIfNecessary: false) as? [[CFString: Any]])
            XCTAssertEqual(attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] as? Bool, true,
                "首帧、连续帧与突发帧都不能因平滑缓冲增加操作延迟")
            XCTAssertTrue(sample.imageBuffer === image)
            XCTAssertEqual(sample.presentationTimeStamp.seconds, Double(source) / 1_000_000, accuracy: 0.000001)
        }
    }
}
