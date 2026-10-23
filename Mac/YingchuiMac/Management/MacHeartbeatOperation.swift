import Foundation

@MainActor
enum MacHeartbeatOperation {
    static func send(_ payload: MacHeartbeat, service: any MacManagementService,
                     sessions: AccountSessionController) async throws -> MacHeartbeatReceipt {
        guard let userID = sessions.user?.id else { throw MacManagementError.unauthorized }
        let generation = sessions.generation
        func check() throws {
            try sessions.check(generation)
            guard sessions.user?.id == userID else { throw CancellationError() }
        }
        let token = try await sessions.accessToken()
        try check()
        let receipt = try await service.heartbeat(payload, token: token)
        try check()
        try receipt.validate()
        return receipt
    }
}
