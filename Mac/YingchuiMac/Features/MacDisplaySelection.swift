import CoreGraphics
import SwiftUI

extension MacHostModel {
    @MainActor
    var displaySelectionBinding: Binding<CGDirectDisplayID?> {
        Binding(
            get: {
                // SwiftUI 在移除控件的事务中仍会读取旧绑定，不能依赖外层列表非空判断。
                guard let selected = self.selectedDisplayID,
                      self.availableDisplays.contains(where: { $0.id == selected }) else { return nil }
                return selected
            },
            set: { selected in
                guard let selected else { return }
                self.selectDisplay(selected)
            }
        )
    }
}
