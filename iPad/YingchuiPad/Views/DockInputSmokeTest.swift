#if DEBUG
import SwiftUI
import YingchuiProtocol

/// 仅在明确调试参数下，把实际程序坞坐标送入现有触摸控制链路。
struct DockInputSmokeTest: ViewModifier {
    @ObservedObject var model: PadConnectionModel
    @State private var started = false
    private struct Plan: Decodable {
        struct Tap: Decodable { let time: Double; let x: Double; let y: Double }
        let events: [Tap]
    }
    func body(content: Content) -> some View {
        content.task(id: model.videoIsPlaying) {
            guard ProcessInfo.processInfo.arguments.contains("--dock-input-probe"),
                  model.videoIsPlaying, !started else { return }
            started = true
            do {
                let support = try FileManager.default.url(for: .applicationSupportDirectory,
                    in: .userDomainMask, appropriateFor: nil, create: true)
                let path = support.appendingPathComponent("com.yingchui.interconnect.pad/Diagnostics/dock-input.json")
                let plan = try await readReadyPlan(at: path)
                // 等待文件传输方完成校验后再清理，不能在读取瞬间删除传输目标。
                defer {
                    do { try FileManager.default.removeItem(at: path) }
                    catch { model.eventLog.record("程序坞输入计划清理失败：\(error.localizedDescription)") }
                }
                guard (1...8).contains(plan.events.count), let stream = model.activeStreamID,
                      let offset = model.clockOffsetMilliseconds, offset.isFinite else { throw failure("实际视频或校时尚未就绪") }
                let hostNow = Date().timeIntervalSince1970 + offset / 1_000
                guard plan.events.allSatisfy({ event in
                    event.time.isFinite && event.time > hostNow && event.time < hostNow + 60 &&
                    event.x.isFinite && event.y.isFinite && (0...1).contains(event.x) && (0...1).contains(event.y)
                }) else { throw failure("真实程序坞输入计划已过期或坐标越界") }
                for (index, event) in plan.events.enumerated() {
                    while true {
                        try Task.checkCancellation()
                        let remaining = event.time - Date().timeIntervalSince1970 - (model.clockOffsetMilliseconds ?? offset) / 1_000
                        if remaining <= 0 { break }
                        try await Task.sleep(nanoseconds: UInt64(min(remaining, 0.05) * 1_000_000_000))
                    }
                    guard model.videoIsPlaying, model.isPaired, model.activeStreamID == stream else { throw failure("实际视频会话已改变") }
                    model.sendTouch(.init(phase: .tap, x: event.x, y: event.y), streamID: stream)
                    model.videoRenderer.pipelineMetrics.benchmark.input()
                    model.eventLog.record("程序坞实机输入：第 \(index + 1) 次，已送入真实触摸控制链路")
                }
            } catch { model.eventLog.record("程序坞实机输入验证失败：\(error.localizedDescription)") }
        }
    }
    private func readReadyPlan(at path: URL) async throws -> Plan {
        // 设备文件传输并非原子替换；旧计划或只写完一部分的文件都不能消费。
        // 等校时和完整的未来计划同时就绪，再开始一次真实输入验证。
        for _ in 0..<200 {
            try Task.checkCancellation()
            if let offset = model.clockOffsetMilliseconds, offset.isFinite,
               let data = try? Data(contentsOf: path),
               let plan = try? JSONDecoder().decode(Plan.self, from: data) {
                let now = Date().timeIntervalSince1970 + offset / 1_000
                if (1...8).contains(plan.events.count), plan.events.allSatisfy({ event in
                    event.time.isFinite && event.time > now && event.time < now + 60 &&
                    event.x.isFinite && event.y.isFinite && (0...1).contains(event.x) && (0...1).contains(event.y)
                }) { return plan }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw failure("等待完整且未过期的真实程序坞输入计划超时")
    }
    private func failure(_ text: String) -> NSError { NSError(domain: "程序坞实机输入", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
#endif
