import Foundation
import YingchuiProtocol

extension PadVideoReceiver {
    func recordRoundTrip(milliseconds: Double, generation: UUID) {
        queue.async { [weak self] in
            guard let self, self.receiverGeneration == generation else { return }
            self.repairTimingPolicy.recordRoundTrip(milliseconds: milliseconds)
            self.applyRepairWaitBudget()
        }
    }

    func applyRepairWaitBudget() {
        guard supportsVideoRepair, pendingRepair == nil else { return }
        let budget = PadVideoReceiveConfiguration.adaptiveRepair ? repairTimingPolicy.waitNanoseconds : 90_000_000
        guard reassembler.updateRepairWaitNanoseconds(budget) else { return }
        if repairWaitNanoseconds != budget {
            repairWaitNanoseconds = budget
            eventLog.recordPeriodic("补发等待预算：\(budget / 1_000_000) 毫秒，依据真实往返与补发耗时调整",
                                    key: "补发等待预算", intervalNanoseconds: 2_000_000_000)
        }
    }

    func scheduleReorderWakeup() {
        if awaitingRecoveryKeyFrame {
            reorderWakeup?.cancel(); reorderWakeup = nil; reorderDeadline = nil
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if supportsVideoRepair, let streamID = expectedStreamID,
           let request = reassembler.repairRequest(now: now), pendingRepair?.frameID != request.frameID {
            pendingRepair = (request.frameID, now, now + repairWaitNanoseconds)
            eventLog.record("请求视频缺片补发：帧 \(request.frameID)，\(request.fragmentIndices.map { "缺少 \($0.count) 片" } ?? "整帧缺失")，等待预算 \(repairWaitNanoseconds / 1_000_000) 毫秒")
            onNeedsVideoRepair?(streamID, request)
        }
        var deadlines = [reassembler.nextDeadline].compactMap { $0 }
        if supportsVideoRepair, PadVideoReceiveConfiguration.adaptiveRepair {
            if let repair = pendingRepair, reassembler.nextDeadline == nil { deadlines.append(repair.deadline) }
            else if let check = reassembler.nextEarlyRepairDeadline { deadlines.append(check) }
        }
        let deadline = deadlines.min()
        guard deadline != reorderDeadline else { return }
        reorderDeadline = deadline
        reorderWakeup?.cancel(); reorderWakeup = nil
        reorderGeneration = UUID()
        guard let deadline else { return }
        let generation = reorderGeneration
        let wakeup = DispatchWorkItem { [weak self] in
            guard let self, self.reorderGeneration == generation else { return }
            self.reorderDeadline = nil; self.reorderWakeup = nil
            self.expireRepairIfNeeded()
            self.deliver(self.reassembler.drain())
            self.scheduleReorderWakeup()
        }
        reorderWakeup = wakeup
        queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline), execute: wakeup)
    }

    private func expireRepairIfNeeded() {
        guard PadVideoReceiveConfiguration.adaptiveRepair, let repair = pendingRepair,
              reassembler.nextDeadline == nil,
              DispatchTime.now().uptimeNanoseconds >= repair.deadline else { return }
        eventLog.record("视频缺片补发超时：帧 \(repair.frameID)，请求关键帧恢复，后续补发预算恢复保守值")
        repairTimingPolicy.recordFailure()
        pendingRepair = nil
        abandonMissingFrameAfterRepairTimeout(repair.frameID)
        requestKeyFrameIfNeeded()
    }
}
