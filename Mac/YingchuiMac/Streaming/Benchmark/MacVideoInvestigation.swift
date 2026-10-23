#if DEBUG
import Foundation
import Network
import YingchuiProtocol

struct MacVideoInvestigationSettings: Decodable, Sendable {
    enum Fault: String, Decodable, Sendable { case hevcStartup, hevcRuntime, controlDisconnect }
    let runID: String
    let fault: Fault?
    let afterFrames: Int?
    private static let consumed = SynchronizedValue(Set<String>())

    static func load() throws -> Self? {
        let file = MacVideoBenchmarkSettings.fileURL.deletingLastPathComponent()
            .appendingPathComponent("video-investigation.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        guard !value.runID.isEmpty, value.runID.count <= 80,
              value.afterFrames.map({ (15...600).contains($0) }) ?? true else {
            throw NSError(domain: "视频链路调查", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "视频链路调查配置无效"])
        }
        return value
    }

    func consume(_ requested: Fault) -> Bool {
        guard fault == requested else { return false }
        return Self.consumed.mutate { values in
            let key = "\(runID)/\(requested.rawValue)"
            guard !values.contains(key), values.count < 128 else { return false }
            values.insert(key)
            return true
        }
    }
}

struct MacVideoInvestigationState {
    var settings: MacVideoInvestigationSettings?
    var recordedCaptureColor = false
    var recordedEncodedColor = false
}

extension MacHostModel {
    func scheduleInvestigationDisconnect(session: HostPeerSession, requestID: UUID, streamID: UUID) {
        do {
            guard let settings = try MacVideoInvestigationSettings.load(), settings.fault == .controlDisconnect else { return }
            networkQueue.asyncAfter(deadline: .now() + .seconds(5)) { [weak self, weak session] in
                guard let self, let session, session.streamRequestID == requestID,
                      session.streamID == streamID, settings.consume(.controlDisconnect) else { return }
                self.eventLog.record("故障注入验证：主动关闭本次控制连接，观察真实重连与视频恢复")
                session.cancel()
            }
        } catch { eventLog.record("读取故障验证配置失败：\(error.localizedDescription)") }
    }
}
#endif
