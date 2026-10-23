import ImageIO
import UIKit
import YingchuiProtocol

/// 不发布 SwiftUI 状态；位置直接送到预览/全屏图层，避免高频整页重绘。
@MainActor
final class PadCursorModel {
    private(set) var streamID: UUID?
    private(set) var position: RemoteCursorPoint?
    private(set) var captureBounds: RemoteCursorRect?
    private(set) var shape: RemoteCursorShape?
    private(set) var image: CGImage?
    private(set) var visible = false
    private var displays: [RemoteCursorRect] = []
    private var sequence: UInt64 = 0
    private var pendingSequence: UInt64 = 0
    private let overlays = NSHashTable<PadCursorOverlayView>.weakObjects()
    private var videoReady = false
    var diagnostics = PadCursorDiagnostics()
    var onDiagnostic: ((String) -> Void)?

    func configure(streamID: UUID, state: RemoteCursorState?) throws {
        reset()
        guard let state else { return }
        guard state.shape != nil else { throw PadCursorError.invalidState }
        self.streamID = streamID
        try apply(state, streamID: streamID)
    }

    func apply(_ state: RemoteCursorState, streamID: UUID) throws {
        guard self.streamID == streamID else { return }
        guard state.isValid else { throw PadCursorError.invalidState }
        diagnostics.remoteUpdates += 1
        if let shape = state.shape {
            guard let source = CGImageSourceCreateWithData(shape.png as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  (1...512).contains(width), (1...512).contains(height),
                  let image = CGImageSourceCreateImageAtIndex(source, 0,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                throw PadCursorError.invalidImage
            }
            self.shape = shape
            self.image = image
        }
        captureBounds = state.captureBounds
        displays = state.displays
        // 系统确认之前保留本地位置；过期回执不能把鼠标拉回去。
        if pendingSequence == 0 || state.acknowledgedInput >= pendingSequence {
            position = state.position
            pendingSequence = 0
            visible = state.visible
        }
        render()
    }

    func buttonInput() -> RemoteCursorInput? {
        guard let position, streamID != nil else { return nil }
        return predict(position)
    }

    func move(deltaX: Double, deltaY: Double) -> RemoteCursorInput? {
        guard let position, streamID != nil, deltaX.isFinite, deltaY.isFinite else { return nil }
        return predict(.init(x: position.x + deltaX, y: position.y + deltaY))
    }

    func touch(_ touch: RemoteTouchInput) -> RemoteCursorInput? {
        guard let bounds = captureBounds, streamID != nil else { return nil }
        return predict(bounds.clamped(.init(x: bounds.x + touch.x * bounds.width,
                                           y: bounds.y + touch.y * bounds.height)))
    }

    private func predict(_ point: RemoteCursorPoint) -> RemoteCursorInput? {
        let start = DispatchTime.now().uptimeNanoseconds
        guard let projected = RemoteCursorRect.project(point, onto: displays) else { return nil }
        sequence += 1
        let input = RemoteCursorInput(position: projected, sequence: sequence)
        guard input.isValid else { return nil }
        position = projected
        pendingSequence = sequence
        visible = true
        render()
        diagnostics.localMoves += 1
        diagnostics.localSubmit.record(from: start, to: DispatchTime.now().uptimeNanoseconds)
        return input
    }

    func attach(_ view: PadCursorOverlayView) {
        overlays.add(view)
        view.model = self
        view.refresh()
    }

    func detach(_ view: PadCursorOverlayView) {
        overlays.remove(view)
        view.model = nil
        view.refresh()
    }

    func showVideo() {
        guard !videoReady else { return }
        videoReady = true
        render()
    }

    var hasUnconfirmedInput: Bool { pendingSequence != 0 }

    var shouldDisplay: Bool { streamID != nil && videoReady && visible }

    func reset() {
        streamID = nil; position = nil; captureBounds = nil; shape = nil; image = nil
        displays = []; visible = false; pendingSequence = 0; videoReady = false
        // 序号跨重连递增，旧流已经注入但尚未处理的事件不能确认新输入。
        render()
    }

    private func render() {
        overlays.allObjects.forEach { $0.refresh() }
        if let report = diagnostics.report(now: DispatchTime.now().uptimeNanoseconds) { onDiagnostic?(report) }
    }
}

enum PadCursorError: LocalizedError {
    case invalidState, invalidImage
    var errorDescription: String? {
        switch self {
        case .invalidState: "Mac 光标状态无效，请重新连接"
        case .invalidImage: "Mac 光标图像损坏或尺寸过大，请重新连接"
        }
    }
}
