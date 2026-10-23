import Foundation
import ServiceManagement

enum LaunchAtLoginState {
    case disabled
    case enabled
    case needsApproval
    case notFound
    case unavailable

    var isSelected: Bool {
        self == .enabled || self == .needsApproval
    }

    var text: String {
        switch self {
        case .disabled: "未启用"
        case .enabled: "已启用"
        case .needsApproval: "等待系统批准"
        case .notFound: "系统未找到登录项"
        case .unavailable: "无法读取系统状态"
        }
    }
}

protocol LaunchAtLoginService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LaunchAtLoginService {}

enum LaunchAtLoginController {
    static var currentState: LaunchAtLoginState {
        state(for: SMAppService.mainApp.status)
    }

    static func state(for status: SMAppService.Status) -> LaunchAtLoginState {
        switch status {
        case .notRegistered: .disabled
        case .enabled: .enabled
        case .requiresApproval: .needsApproval
        case .notFound: .notFound
        @unknown default: .unavailable
        }
    }

    static func setEnabled(_ enabled: Bool, service: any LaunchAtLoginService = SMAppService.mainApp) throws {
        if enabled {
            switch service.status {
            case .enabled, .requiresApproval: return
            // 首次运行也可能返回 notFound，必须实际注册才能得到系统结果。
            case .notRegistered, .notFound: try service.register()
            @unknown default: throw LaunchAtLoginError.unknownStatus
            }
            guard state(for: service.status).isSelected else {
                throw LaunchAtLoginError.registrationNotConfirmed
            }
        } else {
            switch service.status {
            case .notRegistered: return
            case .enabled, .requiresApproval, .notFound: try service.unregister()
            @unknown default: throw LaunchAtLoginError.unknownStatus
            }
            guard service.status == .notRegistered else {
                throw LaunchAtLoginError.unregistrationNotConfirmed
            }
        }
    }
}

private enum LaunchAtLoginError: LocalizedError {
    case unknownStatus
    case registrationNotConfirmed
    case unregistrationNotConfirmed

    var errorDescription: String? {
        switch self {
        case .unknownStatus: "无法识别系统登录项状态"
        case .registrationNotConfirmed: "系统尚未确认登录项注册，请在系统设置的登录项中检查"
        case .unregistrationNotConfirmed: "系统尚未确认登录项已移除，请在系统设置的登录项中检查"
        }
    }
}
