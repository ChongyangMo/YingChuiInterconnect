import SwiftUI
import UIKit

/// 菜单只在打开时取最新数据；投屏刷新不能替换正在展示的菜单树。
struct StableMenuButton: UIViewRepresentable {
    @Environment(\.colorSchemeContrast) private var contrast
    let isFullScreen: Bool
    var makeItems: () -> [UIMenuElement]

    func makeUIView(context: Context) -> SnapshotMenuButton {
        SnapshotMenuButton(makeItems: makeItems)
    }

    func updateUIView(_ button: SnapshotMenuButton, context: Context) {
        button.makeItems = makeItems
        button.applyAppearance(fullScreen: isFullScreen, increasedContrast: contrast == .increased)
    }
}

@MainActor
final class SnapshotMenuButton: UIButton {
    var makeItems: () -> [UIMenuElement]
    private var appearance: Int?

    init(makeItems: @escaping () -> [UIMenuElement]) {
        self.makeItems = makeItems
        super.init(frame: .zero)
        showsMenuAsPrimaryAction = true
        accessibilityLabel = "更多"
        accessibilityIdentifier = "pad-more-menu"
        menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.makeItems() ?? [])
        }])
    }

    required init?(coder: NSCoder) { fatalError("不支持从归档创建菜单按钮") }

    func applyAppearance(fullScreen: Bool, increasedContrast: Bool) {
        let newAppearance = (fullScreen ? 1 : 0) + (increasedContrast ? 2 : 0)
        guard appearance != newAppearance else { return }
        appearance = newAppearance
        let symbol = fullScreen ? "ellipsis" : "ellipsis.circle"
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)
        tintColor = .systemBlue.withAlphaComponent(fullScreen ? (increasedContrast ? 0.85 : 0.4) : 1)
    }
}
