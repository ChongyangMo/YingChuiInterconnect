import Foundation
import YingchuiProtocol

extension MacScreenStreamer {
    func repairVideo(_ request: VideoRepairRequest, streamID: UUID) {
        captureQueue.async { [weak self] in
            guard let self, self.streamID == streamID, self.udpConnection != nil || self.mediaPacketSink != nil else { return }
            let connection = self.udpConnection
            guard let packets = self.repairCache.take(request),
                  self.shouldSend(datagramCount: packets.count) else {
                self.eventLog.record("视频缺片无法补发：帧 \(request.frameID)，缓存或发送额度不足，立即请求关键帧恢复")
                self.stateLock.withLock { self.forceNextKeyFrame = true }
                return
            }
            let generation = self.stateLock.withLock { self.captureGeneration }
            self.sendDatagrams(packets, copies: 1, connection: connection,
                generation: generation, priority: true)
            self.eventLog.record("视频缺片补发已提交：帧 \(request.frameID)，\(packets.count) 个分片")
        }
    }
}
