import SwiftUI
import YingchuiProtocol

struct PadDisplayModeMenu: View {
    @ObservedObject var model: PadConnectionModel

    var body: some View {
        Menu {
            ForEach([RemoteDisplayMode.mirror, .extended], id: \.self) { mode in
                Button { model.selectDisplayMode(mode) } label: {
                    if model.selectedDisplayMode == mode {
                        Label(mode.title, systemImage: "checkmark")
                    } else { Text(mode.title) }
                }
            }
            if model.selectedDisplayMode == .extended || model.activeDisplayState?.mode == .extended {
                Menu("屏幕位置") {
                    ForEach(RemoteDisplayPlacement.allCases, id: \.self) { placement in
                        Button { model.selectDisplayPlacement(placement) } label: {
                            if model.displayPlacement == placement {
                                Label(placement.title, systemImage: "checkmark")
                            } else { Text(placement.title) }
                        }
                    }
                }
            }
            if model.isStreaming {
                Divider()
                Button("鼠标移回 iPad", systemImage: "cursorarrow") { model.returnPointerToDisplay() }
                    .disabled(model.displayModeChanging)
            }
        } label: {
            Label(model.displayModeTitle, systemImage: "display.2")
        }
        .frame(minHeight: 44)
        .accessibilityLabel("显示模式：\(model.displayModeTitle)")
    }
}
