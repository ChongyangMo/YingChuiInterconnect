import AppKit
import ApplicationServices
import YingchuiProtocol

/// 只读系统光标；不隐藏 Mac 自身光标，不拦截或修改系统输入。
@MainActor
final class MacCursorMonitor {
    private let displayID: CGDirectDisplayID
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var timer: DispatchSourceTimer?
    private var acknowledgedInput: UInt64 = 0
    private var lastState: RemoteCursorState?
    private var shape: RemoteCursorShape?
    private var tick = 0
    var onUpdate: ((RemoteCursorState) -> Void)?
    var onFailure: ((String) -> Void)?

    init(displayID: CGDirectDisplayID) { self.displayID = displayID }

    func prepare() throws -> RemoteCursorState {
        let mask = [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged,
                    .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
            .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
            options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<MacCursorMonitor>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { monitor.observed(type, event: event) }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            throw CursorError.unavailable("无法监听系统鼠标，请检查辅助功能权限")
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        do {
            shape = try Self.readShape()
            let initial = try snapshot(includeShape: true)
            lastState = initial
            return initial
        } catch { stop(); throw error }
    }

    func start() {
        guard timer == nil, eventTap != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.sample() }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel(); timer = nil
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false); CFMachPortInvalidate(eventTap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        eventTap = nil; runLoopSource = nil
        onUpdate = nil; onFailure = nil
    }

    private func observed(_ type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let failure = onFailure
            stop()
            failure?("系统光标监听已停止，请重新连接")
            return
        }
        if let sequence = RemoteCursorInput.sequence(fromEventTag: event.getIntegerValueField(.eventSourceUserData)) {
            acknowledgedInput = max(acknowledgedInput, sequence)
        }
    }

    private func sample() {
        do {
            tick += 1
            var changedShape = false
            // 图形仅每 100 毫秒检查一次；位置按 60 Hz 采样，不逐事件编码图片。
            if tick % 6 == 0 {
                let next = try Self.readShape()
                changedShape = next != shape
                shape = next
            }
            let state = try snapshot(includeShape: changedShape)
            if let lastState, state.position == lastState.position,
               state.captureBounds == lastState.captureBounds, state.displays == lastState.displays,
               state.visible == lastState.visible, state.acknowledgedInput == lastState.acknowledgedInput,
               !changedShape { return }
            lastState = state
            onUpdate?(state)
        } catch {
            let failure = onFailure
            stop()
            failure?(error.localizedDescription)
        }
    }

    private func snapshot(includeShape: Bool) throws -> RemoteCursorState {
        guard CGDisplayIsActive(displayID) != 0, let point = CGEvent(source: nil)?.location else {
            throw CursorError.unavailable("无法读取回传屏幕的光标位置")
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success, count > 0 else {
            throw CursorError.unavailable("无法读取光标可移动的屏幕范围")
        }
        func rect(_ bounds: CGRect) -> RemoteCursorRect {
            .init(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height)
        }
        let result = RemoteCursorState(position: .init(x: point.x, y: point.y),
            captureBounds: rect(CGDisplayBounds(displayID)),
            displays: ids.prefix(Int(count)).map { rect(CGDisplayBounds($0)) },
            visible: YCCursorIsVisible(), acknowledgedInput: acknowledgedInput,
            shape: includeShape ? shape : nil)
        guard result.isValid else { throw CursorError.unavailable("系统光标坐标或图像无效") }
        return result
    }

    static func readShape() throws -> RemoteCursorShape {
        // current 只返回本应用光标；currentSystem 才能读取被控制应用的真实形状。
        guard let cursor = NSCursor.currentSystem else {
            throw CursorError.unavailable("无法读取系统光标图像")
        }
        let size = cursor.image.size
        guard size.width >= 1, size.height >= 1, size.width <= 256, size.height <= 256,
              let image = cursor.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: Int(ceil(size.width * 2)), height: Int(ceil(size.height * 2)),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CursorError.unavailable("系统光标图像尺寸无效")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        guard let rendered = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]) else {
            throw CursorError.unavailable("系统光标图像编码失败")
        }
        let result = RemoteCursorShape(png: png, width: size.width, height: size.height,
            hotSpot: .init(x: cursor.hotSpot.x, y: cursor.hotSpot.y))
        guard result.isValid else { throw CursorError.unavailable("系统光标图像超出传输范围") }
        return result
    }
}

enum CursorError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { switch self { case .unavailable(let text): return text } }
}
