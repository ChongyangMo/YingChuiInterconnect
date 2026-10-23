import SwiftUI
import YingchuiProtocol

struct PadVideoToolbar: View {
    @ObservedObject var model: PadConnectionModel
    @Binding var isFullScreen: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { title; Spacer(minLength: 8); options; actions }
            VStack(spacing: 4) {
                HStack { title; Spacer(); options }
                HStack { Spacer(); actions }
            }
            VStack(alignment: .leading, spacing: 4) {
                title
                PadDisplayModeMenu(model: model)
                resolutionPicker
                actions
            }
        }
    }

    private var title: some View {
        Label("Mac 屏幕", systemImage: model.isStreaming ? "play.display" : "display")
            .font(.headline)
            .fixedSize()
    }

    private var options: some View {
        HStack(spacing: 8) {
            PadDisplayModeMenu(model: model)
            resolutionPicker
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder private var resolutionPicker: some View {
            if !model.resolutionOptions.isEmpty {
                Picker(selection: Binding(get: { model.selectedQuality }, set: { model.selectQuality($0) })) {
                    ForEach(model.resolutionOptions) { quality in
                        if let resolution = model.resolutionText(for: quality) {
                            Text(resolution).monospacedDigit().tag(quality)
                        }
                    }
                } label: { EmptyView() }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(minHeight: 44)
                .accessibilityLabel("分辨率")
            }
    }

    @ViewBuilder private var actions: some View {
        if model.isStreaming {
            Button(role: .destructive) { model.stopStreaming() } label: {
                YingchuiActionLabel(title: "停止回传", systemImage: "stop.fill", isWorking: !model.videoIsPlaying)
            }
            .buttonStyle(.yingchuiSecondary).frame(minHeight: 44).fixedSize()
            Button("全屏", systemImage: "arrow.up.left.and.arrow.down.right") { isFullScreen = true }
                .buttonStyle(.yingchuiPrimary).frame(minHeight: 44).fixedSize()
        } else {
            Button { model.startStreaming() } label: {
                YingchuiActionLabel(title: "开始回传", systemImage: "play.fill")
            }
            .buttonStyle(.yingchuiPrimary).frame(minHeight: 44).fixedSize()
        }
    }
}
