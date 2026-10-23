import SwiftUI

struct PadDiagnosticsPanel: View {
    @ObservedObject var model: PadConnectionModel
    let onForget: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240))], spacing: 8) {
                metric(.networkRTT, value: milliseconds(model.roundTripMilliseconds))
                metric(.networkP95, value: milliseconds(model.roundTripP95Milliseconds))
                metric(.controlLatency, value: milliseconds(model.controlRoundTripMilliseconds))
                metric(.controlP95, value: milliseconds(model.controlRoundTripP95Milliseconds))
                metric(.inputFrame, value: milliseconds(model.interactionToVideoFrameMilliseconds))
                metric(.inputFrameP95, value: milliseconds(model.interactionToVideoFrameP95Milliseconds))
                metric(.captureLatency, value: milliseconds(model.estimatedVideoLatencyMilliseconds))
                metric(.captureP95, value: milliseconds(model.videoLatencyP95Milliseconds))
                metric(.receivedDecoded, value: "\(model.videoPacketsReceived) / \(model.videoFramesDecoded)")
                metric(.droppedFrames, value: "\(model.videoFramesDropped)")
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actions }
                VStack(alignment: .leading, spacing: 8) { actions }
            }
        }
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var actions: some View {
        PadDeveloperActions(model: model, showsHelp: true)
        Button("忘记此 Mac", role: .destructive, action: onForget)
            .buttonStyle(.yingchuiRow)
            .disabled(model.connectedHostName == nil)
            .frame(minHeight: 44)
    }

    private func metric(_ topic: PadSettingsTopic, value: String) -> some View {
        PadSettingsInfoButton(topic: topic) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Text(topic.title)
                    Spacer(minLength: 4)
                    Text(value).monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(topic.title)
                    Text(value).monospacedDigit()
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.subheadline)
            .padding(12)
            .frame(minHeight: 44)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(topic.title)
        .accessibilityValue(value)
        .accessibilityHint("显示用途说明")
    }

    private func milliseconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(1)))) ms"
    }
}
