import UIKit
import YingchuiProtocol

/// 一次展开使用一份完整快照，子菜单不订阅连接模型的统计刷新。
@MainActor
struct PadMoreMenuItems {
    let model: PadConnectionModel
    let showKeyboard: () -> Void
    let exitFullScreen: (() -> Void)?
    let exportDiagnostics: (String) -> Void
    var preferences: UserDefaults = .standard

    func makeItems() -> [UIMenuElement] {
        let controlMode = preferences.string(forKey: PadControlMode.preferenceKey)
            ?? PadControlMode.mouseKeyboard.rawValue
        var items: [UIMenuElement] = [
            UIMenu(title: "操作方式", children: PadControlMode.allCases.map { mode in
                action(mode.title, selected: mode.rawValue == controlMode) {
                    preferences.set(mode.rawValue, forKey: PadControlMode.preferenceKey)
                }
            }),
            action("键盘", image: "keyboard", enabled: model.isPaired, perform: showKeyboard),
            displayMenu(),
            UIMenu(title: "画质", children: model.resolutionOptions.map { quality in
                action(model.resolutionText(for: quality) ?? quality.rawValue,
                       enabled: model.isPaired, selected: model.selectedQuality == quality) {
                    model.selectQuality(quality)
                }
            }),
            action("声音", selected: model.isAudioEnabled) { model.setAudioEnabled(!model.isAudioEnabled) },
            action("显示回传信息", image: "chart.bar",
                   selected: preferences.object(forKey: PadStreamMetrics.visibilityKey) as? Bool ?? true) {
                let visible = preferences.object(forKey: PadStreamMetrics.visibilityKey) as? Bool ?? true
                preferences.set(!visible, forKey: PadStreamMetrics.visibilityKey)
            },
            action("发送剪贴板到 Mac", image: "clipboard", enabled: model.isPaired) { model.sendClipboard() },
            action("复制 Mac 剪贴板", image: "doc.on.clipboard", enabled: model.isPaired) { model.receiveClipboard() }
        ]
        if preferences.bool(forKey: PadSettings.developerModeKey) {
            items.append(UIMenu(options: .displayInline, children: [
                action("测试延迟", image: "waveform.path.ecg", enabled: model.isPaired) { model.sendPing() },
                action("请求关键帧", image: "photo.badge.arrow.down", enabled: model.isStreaming) { model.requestKeyFrame() },
                action("导出诊断", image: "square.and.arrow.up") { exportDiagnostics(model.diagnosticSummary) }
            ]))
        }
        if let exitFullScreen {
            items.append(UIMenu(options: .displayInline, children: [
                action("退出全屏", image: "arrow.down.right.and.arrow.up.left", perform: exitFullScreen)
            ]))
        }
        return items
    }

    private func displayMenu() -> UIMenu {
        var items: [UIMenuElement] = [RemoteDisplayMode.mirror, .extended].map { mode in
            action(mode.title, selected: model.selectedDisplayMode == mode) { model.selectDisplayMode(mode) }
        }
        if model.selectedDisplayMode == .extended || model.activeDisplayState?.mode == .extended {
            items.append(UIMenu(title: "屏幕位置", children: RemoteDisplayPlacement.allCases.map { placement in
                action(placement.title, selected: model.displayPlacement == placement) { model.selectDisplayPlacement(placement) }
            }))
        }
        if model.isStreaming {
            items.append(UIMenu(options: .displayInline, children: [
                action("鼠标移回 iPad", image: "cursorarrow", enabled: !model.displayModeChanging) {
                    model.returnPointerToDisplay()
                }
            ]))
        }
        return UIMenu(title: model.displayModeTitle, image: UIImage(systemName: "display.2"), children: items)
    }

    private func action(_ title: String, image: String? = nil, enabled: Bool = true,
                        selected: Bool = false, perform: @escaping () -> Void) -> UIAction {
        UIAction(title: title, image: image.flatMap { UIImage(systemName: $0) },
                 attributes: enabled ? [] : .disabled, state: selected ? .on : .off) { _ in perform() }
    }
}
