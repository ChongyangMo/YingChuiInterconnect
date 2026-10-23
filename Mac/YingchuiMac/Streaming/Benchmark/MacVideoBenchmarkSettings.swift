#if DEBUG
import Foundation
import YingchuiProtocol

struct MacVideoBenchmarkSettings: Decodable {
    let runID: String
    let codec: VideoCodec
    let maximumPendingEncodes: Int
    let bitRate: Int
    let idleFrameRate: Int?
    let acceleratesLargeFrames: Bool?
    let lowLatencyRateControl: Bool?

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.yingchui.interconnect.mac/Diagnostics/video-benchmark.json")
    }

    static func load() throws -> Self? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let settings = try JSONDecoder().decode(Self.self, from: Data(contentsOf: fileURL))
        guard !settings.runID.isEmpty, settings.runID.count <= 80,
              (1...2).contains(settings.maximumPendingEncodes),
              (1_000_000...12_000_000).contains(settings.bitRate),
              settings.idleFrameRate == nil || settings.idleFrameRate == 60 else {
            throw NSError(domain: "视频性能对比", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "视频性能对比配置无效"])
        }
        return settings
    }
}
#endif
