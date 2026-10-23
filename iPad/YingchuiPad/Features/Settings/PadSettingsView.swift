import SwiftUI

enum PadSettings {
    static let developerModeKey = "YingchuiDeveloperMode"
}

struct PadSettingsView: View {
    @ObservedObject var model: PadConnectionModel
    @AppStorage(PadSettings.developerModeKey) private var developerMode = false
    @AppStorage(PadControlMode.preferenceKey) private var mode: PadControlMode = .mouseKeyboard
    let onForget: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                YingchuiPanel {
                    HStack(spacing: 12) {
                        YingchuiPanelIcon(systemName: "cursorarrow.motionlines")
                        PadSettingsHelpLabel(topic: .controlMode)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18).padding(.top, 14)
                    PadSettingsControlChoices(mode: $mode)
                        .padding(18).padding(.top, 2)
                }
                YingchuiPanel {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            developerHeading.fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 12)
                            developerToggle
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            developerHeading
                            developerToggle.frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .padding(18)
                }
                if developerMode {
                    YingchuiPanel {
                        PadDiagnosticsPanel(model: model, onForget: onForget).padding(18)
                    }
                    .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
            .frame(maxWidth: 640)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background { YingchuiPanelBackground() }
        .yingchuiStatusMotion(developerMode)
    }

    private var developerHeading: some View {
        HStack(spacing: 12) {
            YingchuiPanelIcon(systemName: "chevron.left.forwardslash.chevron.right")
            PadSettingsHelpLabel(topic: .developerMode)
        }
    }

    private var developerToggle: some View {
        Toggle("开发者模式", isOn: $developerMode).labelsHidden().tint(.accentColor)
    }
}
