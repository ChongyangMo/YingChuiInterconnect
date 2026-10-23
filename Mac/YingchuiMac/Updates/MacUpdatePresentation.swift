import Foundation
import Sparkle

/// 系统和更新组件的错误保留原始信息，仅将展示文案转换为中文。
enum MacUpdatePresentation {
    static func failure(_ error: Error) -> NSError {
        replacingText(in: error as NSError, title: "更新未完成", detail: failureMessage(error))
    }

    static func failureMessage(_ error: Error) -> String {
        if let error = error as? MacManagementError { return error.localizedDescription }
        let failure = error as NSError
        if failure.domain == NSURLErrorDomain {
            switch failure.code {
            case NSURLErrorTimedOut: return "连接更新服务超时，请稍后重试。"
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return "网络连接已中断，请连接网络后重试。"
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
                return "无法连接更新服务，请检查网络后重试。"
            case NSURLErrorCancelled: return "本次更新已取消。"
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid:
                return "无法验证更新服务的安全连接，请检查系统时间或稍后重试。"
            default: return "更新请求失败（错误代码 \(failure.code)），请稍后重试。"
            }
        }
        if failure.domain == SUSparkleErrorDomain {
            switch failure.code {
            case 1...7: return "应用的更新配置无效，请联系开发者。"
            case 1000, 1002, 1004: return "无法读取更新信息，请稍后重试。"
            case 1003, 1005: return "请退出应用，将它移至“应用程序”文件夹后重新打开，再检查更新。"
            case 1006, 1007: return "无法显示更新说明，请稍后重试。"
            case 2000: return "无法创建更新临时文件，请检查磁盘空间和文件权限。"
            case 2001: return "更新下载失败，请检查网络后重试。"
            case 3000: return "更新包解压失败，请重新下载。"
            case 3001, 3002, 4009: return "更新包的安全校验未通过，已停止安装，请联系开发者。"
            case 4001, 4012: return "没有权限安装更新，请在“系统设置”的“隐私与安全性”中允许本应用管理应用程序。"
            case 4004: return "更新后未能重新启动应用，请手动打开鹰锤互联。"
            case 4006: return "更新版本低于当前版本，已停止安装。"
            case 4007: return "本次更新已取消。"
            case 4008: return "更新等待安装授权，可稍后继续。"
            case 4000...4010: return "更新安装失败，请重新打开应用后重试。"
            default: break
            }
        }
        return "更新未完成（错误代码 \(failure.code)），请稍后重试。"
    }

    static func noUpdate(_ error: Error, host: Bundle = .main) -> NSError {
        let failure = error as NSError
        let reason = (failure.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
        let version = host.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let title: String
        let detail: String
        switch reason {
        case Int(SPUNoUpdateFoundReason.onLatestVersion.rawValue):
            title = "已是最新版本"
            detail = version.map { "鹰锤互联 \($0) 已是当前最新版本。" } ?? "当前没有可用的新版本。"
        case Int(SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue):
            title = "无需更新"
            detail = "当前安装的版本高于已发布版本。"
        case Int(SPUNoUpdateFoundReason.systemIsTooOld.rawValue):
            title = "需要升级系统"
            detail = "当前系统版本过低，无法安装此更新。请先升级系统。"
        case Int(SPUNoUpdateFoundReason.systemIsTooNew.rawValue):
            title = "系统版本不兼容"
            detail = "此更新暂不支持当前系统版本，请等待兼容版本。"
        case Int(SPUNoUpdateFoundReason.hardwareDoesNotSupportARM64.rawValue):
            title = "处理器不兼容"
            detail = "此更新仅适用于搭载苹果芯片的电脑。"
        default:
            title = "暂无可用更新"
            detail = "当前没有可安装的新版本。"
        }
        return replacingText(in: failure, title: title, detail: detail)
    }

    private static func replacingText(in error: NSError, title: String, detail: String) -> NSError {
        var info = error.userInfo
        info[NSLocalizedDescriptionKey] = title
        info[NSLocalizedRecoverySuggestionErrorKey] = detail
        info[NSLocalizedFailureReasonErrorKey] = nil
        info[NSLocalizedRecoveryOptionsErrorKey] = ["好"]
        return NSError(domain: error.domain, code: error.code, userInfo: info)
    }
}
