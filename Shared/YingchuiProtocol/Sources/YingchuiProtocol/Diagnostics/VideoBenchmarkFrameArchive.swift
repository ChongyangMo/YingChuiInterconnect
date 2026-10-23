#if DEBUG
import Foundation
import OSLog

/// 逐帧采样独立保存，避免常规日志的单条长度限制；只在明确开启性能采样时调用。
public final class VideoBenchmarkFrameArchive: @unchecked Sendable {
    public static let shared = VideoBenchmarkFrameArchive()
    private let queue = DispatchQueue(label: "com.yingchui.video-benchmark-archive", qos: .utility)
    private let log = Logger(subsystem: "com.yingchui.runtime", category: "视频逐帧采样")
    private var counts: [UUID: Int] = [:]
    // 调用方仅提交标量、字典与数组构成的不可变值快照，后台独占序列化。
    private struct Snapshot: @unchecked Sendable { let value: [String: Any] }

    public func append(_ record: [String: Any], streamID: UUID) {
        let snapshot = Snapshot(value: record)
        queue.async { [self] in
            let count = counts[streamID] ?? 0
            guard count < 128 else {
                if count == 128 { log.error("本流逐帧采样达到一百二十八个窗口上限，停止保存"); counts[streamID] = 129 }
                return
            }
            do {
                let data = try JSONSerialization.data(withJSONObject: snapshot.value, options: [.sortedKeys])
                guard let bundle = Bundle.main.bundleIdentifier else { throw CocoaError(.fileWriteInvalidFileName) }
                let support = try FileManager.default.url(for: .applicationSupportDirectory,
                    in: .userDomainMask, appropriateFor: nil, create: true)
                let directory = support.appendingPathComponent(bundle).appendingPathComponent("Diagnostics/VideoBenchmark")
                    .appendingPathComponent(streamID.uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent(String(format: "%04d.json", count)), options: .atomic)
                counts[streamID] = count + 1
            } catch { log.error("视频逐帧采样保存失败：\(error.localizedDescription, privacy: .public)") }
        }
    }
}
#endif
