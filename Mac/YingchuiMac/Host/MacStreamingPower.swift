import Foundation

extension MacHostModel {
    func releaseStreamPowerActivity() {
        do { try streamPowerActivity.end() }
        catch { publishStatus("释放回传电源保护失败：\(error.localizedDescription)") }
    }
}
