import SwiftUI

struct PadStreamMetricsView: View {
    @AppStorage(PadStreamMetrics.visibilityKey) private var isVisible = true
    let metrics: PadStreamMetrics

    var body: some View {
        if isVisible {
            // 即使接收端停止回调，也让过期读数消失；不驱动视频视图刷新。
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let now = DispatchTime.now().uptimeNanoseconds
                let fresh = metrics.isFresh(metrics.updatedAt, now: now)
                let fps = fresh ? metrics.framesPerSecond : nil
                let latency = metrics.isFresh(metrics.pingAt, now: now) ? metrics.roundTripMilliseconds : nil
                let audio = fresh ? metrics.audioMilliseconds : nil
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        picture(fps)
                        timing(latency, audio)
                    }
                    VStack(spacing: 5) {
                        picture(fps)
                        timing(latency, audio)
                    }
                }
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.95))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityElement(children: .combine)
                .accessibilityHint("帧率为实际解码速度。网络延迟为往返时间。声音缓冲为待播放时长。")
            }
            .allowsHitTesting(false)
            .transaction { $0.animation = nil }
        }
    }

    private func picture(_ fps: Double?) -> some View {
        HStack(spacing: 16) {
            Text("解码 \(fps.map { String(format: "%.1f", $0) } ?? "—") 帧/秒")
            Text(metrics.resolution ?? "等待画面")
                .accessibilityLabel("分辨率 \(metrics.resolution ?? "等待画面")")
        }
        .fixedSize()
    }

    private func timing(_ latency: Double?, _ audio: Double?) -> some View {
        HStack(spacing: 16) {
            Text("往返 \(milliseconds(latency)) 毫秒")
            Text("声音缓冲 \(milliseconds(audio)) 毫秒")
        }
        .fixedSize()
    }

    private func milliseconds(_ value: Double?) -> String {
        value.map { String(format: "%.0f", $0) } ?? "—"
    }


}
