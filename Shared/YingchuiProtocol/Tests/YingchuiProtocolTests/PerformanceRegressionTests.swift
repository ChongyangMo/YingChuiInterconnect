import Foundation
import Testing
@testable import YingchuiProtocol

@Test func reassemblerCopiesRemainIndependentDuringOutOfOrderAssembly() throws {
    let payload = Data(repeating: 42, count: 200_000)
    let fragments = try VideoDatagramCodec.fragment(accessUnit: payload, streamID: UUID(), frameID: 0,
        presentationTimeMicroseconds: 1, isKeyFrame: true).map(VideoDatagramCodec.decode)
    var a = VideoFrameReassembler()
    #expect(a.append(fragments[0]) == nil)
    var b = a
    var completedA: CompletedVideoFrame?
    for fragment in fragments.dropFirst().reversed() { completedA = a.append(fragment) ?? completedA }
    #expect(completedA?.accessUnit == payload)
    var completedB: CompletedVideoFrame?
    for fragment in fragments.dropFirst() { completedB = b.append(fragment) ?? completedB }
    #expect(completedB?.accessUnit == payload)
    #expect(a.append(fragments[0]) == nil)
}

@Test func diagnosticSnapshotsDeduplicateButErrorsRemainVisible() {
    let log = DiagnosticEventLog(subsystem: "测试", category: "诊断")
    log.recordChange("无物理屏", key: "显示器")
    log.recordChange("无物理屏", key: "显示器")
    log.recordChange("有物理屏", key: "显示器")
    log.record("连接错误")
    log.record("连接错误")
    #expect(log.recentMessages(limit: 10) == ["无物理屏", "有物理屏", "连接错误", "连接错误"])
}

@Test func periodicDiagnosticsRespectMonotonicWindow() {
    let log = DiagnosticEventLog(subsystem: "测试", category: "诊断")
    log.recordPeriodic("统计一", key: "播放", intervalNanoseconds: 10, now: 0)
    log.recordPeriodic("统计二", key: "播放", intervalNanoseconds: 10, now: 9)
    log.recordPeriodic("统计三", key: "播放", intervalNanoseconds: 10, now: 10)
    #expect(log.recentMessages(limit: 10) == ["统计一", "统计三"])
}
