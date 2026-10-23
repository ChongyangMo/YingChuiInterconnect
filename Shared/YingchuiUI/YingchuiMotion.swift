import SwiftUI

/// 状态变化使用短过渡；不将动画绑定到视频帧、延迟统计等高频数据。
struct YingchuiStatusMotion<Value: Equatable>: ViewModifier {
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: value)
    }
}

extension View {
    func yingchuiStatusMotion<Value: Equatable>(_ value: Value) -> some View {
        modifier(YingchuiStatusMotion(value: value))
    }
}

struct YingchuiActionLabel: View {
    let title: String
    let systemImage: String
    var isWorking = false

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Image(systemName: systemImage).opacity(isWorking ? 0 : 1)
                if isWorking { ProgressView().controlSize(.small) }
            }
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
            Text(title)
        }
        .yingchuiStatusMotion(isWorking)
        .accessibilityValue(isWorking ? "正在处理" : "")
    }
}
