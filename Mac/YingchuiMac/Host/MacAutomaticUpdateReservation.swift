import Foundation
import YingchuiProtocol

extension MacHostModel {
    /// 在真实网络队列上确认没有连接或回传准备任务，避免界面状态发布延迟造成安装竞态。
    func reserveAutomaticUpdate() async -> Bool {
        await withCheckedContinuation { continuation in
            networkQueue.async { [weak self] in
                guard let self, self.sessions.isEmpty, self.streamingSessionID == nil else {
                    continuation.resume(returning: false)
                    return
                }
                self.automaticUpdateBarrier.set(true)
                continuation.resume(returning: true)
            }
        }
    }
}
