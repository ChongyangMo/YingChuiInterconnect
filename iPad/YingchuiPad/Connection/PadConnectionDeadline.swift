import Foundation
import Network
import YingchuiProtocol

/// 各阶段独立计时，普通心跳不能延长身份确认或配对响应期限。
enum PadConnectionPhase: Equatable {
    case connecting, identifying, pairing

    var timeoutSeconds: Double {
        switch self {
        case .connecting: 10
        case .identifying: 5
        case .pairing: 10
        }
    }

    func timeoutSeconds(for endpoint: NWEndpoint) -> Double {
        if self == .connecting, case .service = endpoint { return 30 }
        return timeoutSeconds
    }

    var failureMessage: String {
        switch self {
        case .connecting: "连接 Mac 超时，请检查网络后重新选择 Mac"
        case .identifying: "Mac 身份确认超时，请重新连接"
        case .pairing: "配对响应超时，请重新连接后输入配对码"
        }
    }
}

extension PadConnectionModel {
    func armConnectionDeadline(_ phase: PadConnectionPhase, on connection: NWConnection) {
        cancelConnectionDeadline()
        connectionPhase = phase
        let epoch = connectionEpoch.value
        let item = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.expireConnectionDeadline(phase, on: connection, epoch: epoch)
        }
        connectionDeadlineWorkItem = item
        networkQueue.asyncAfter(deadline: .now() + phase.timeoutSeconds(for: connection.endpoint), execute: item)
    }

    func cancelConnectionDeadline() {
        connectionDeadlineWorkItem?.cancel()
        connectionDeadlineWorkItem = nil
        connectionPhase = nil
    }

    func expireConnectionDeadline(_ phase: PadConnectionPhase, on connection: NWConnection, epoch: UUID) {
        guard connectionEpoch.value == epoch, self.connection === connection,
              connectionPhase == phase else { return }
        if phase == .connecting, case .service = desiredEndpoint {
            let message = "附近设备连接超时，将重新查找并连接，请保持两端无线局域网开启"
            eventLog.record(message)
            handleConnectionClosed(connection, reason: message)
        } else {
            // 身份确认和配对超时仍明确终止，不能绕过安全验证自动继续。
            desiredEndpoint = nil
            wantsStreaming = false
            eventLog.record(phase.failureMessage)
            handleConnectionClosed(connection, reason: phase.failureMessage)
        }
    }
}
