import SwiftUI

struct TransferStatusView: View {
    @ObservedObject var model: PadConnectionModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if !model.transferStatus.isEmpty {
                Text(model.transferStatus).font(.callout)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule()).padding()
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
        .yingchuiStatusMotion(model.transferStatus.isEmpty)
        .task(id: model.transferStatus) {
            let status = model.transferStatus
            guard !status.isEmpty, !status.hasPrefix("正在") else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            if model.transferStatus == status { model.transferStatus = "" }
        }
    }
}
