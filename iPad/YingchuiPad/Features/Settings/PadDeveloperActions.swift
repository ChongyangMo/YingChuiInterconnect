import SwiftUI

struct PadDeveloperActions: View {
    @ObservedObject var model: PadConnectionModel
    var showsHelp = false
    @AppStorage(PadSettings.developerModeKey) private var developerMode = false

    var body: some View {
        if developerMode {
            HStack(spacing: 0) {
                Button("测试延迟", systemImage: "waveform.path.ecg") { model.sendPing() }
                    .buttonStyle(.yingchuiRow)
                    .disabled(!model.isPaired)
                    .frame(minHeight: 44)
                if showsHelp { PadSettingsHelpLabel(topic: .ping, iconOnly: true) }
            }
            HStack(spacing: 0) {
                Button("请求关键帧", systemImage: "photo.badge.arrow.down") { model.requestKeyFrame() }
                    .buttonStyle(.yingchuiRow)
                    .disabled(!model.isStreaming)
                    .frame(minHeight: 44)
                if showsHelp { PadSettingsHelpLabel(topic: .keyframe, iconOnly: true) }
            }
            HStack(spacing: 0) {
                ShareLink(item: model.diagnosticSummary) {
                    Label("导出诊断", systemImage: "square.and.arrow.up")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.yingchuiRow)
                if showsHelp { PadSettingsHelpLabel(topic: .diagnostics, iconOnly: true) }
            }
        }
    }
}
