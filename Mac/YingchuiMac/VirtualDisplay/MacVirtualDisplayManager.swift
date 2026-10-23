import CoreGraphics
import Foundation
import YingchuiProtocol

struct MacVirtualDisplaySession: Sendable {
    let displayID: CGDirectDisplayID
    let physicalDisplayID: CGDirectDisplayID?
    let pixelDimensions: StreamDimensions
    let frameRate: Int
}

final class MacVirtualDisplayManager: @unchecked Sendable {
    static let displayName = "鹰锤互联 iPad Retina"

    private let recoveryStore: DisplayRecoveryStore
    var hasPendingRecovery: Bool { lock.withLock { recoveryStore.exists } }
    private let lock = NSLock()
    private let cleanupQueue = DispatchQueue(label: "com.yingchui.mac.virtual-display-cleanup")
    private let eventLog = DiagnosticEventLog(
        subsystem: "com.yingchui.interconnect.mac",
        category: "虚拟显示器"
    )
    var onRestored: (@Sendable () -> Void)?
    var onFailure: (@Sendable (String) -> Void)?
    private var captureRecovery = DisplayCaptureRecoveryWindow()
    private var observedPhysicalDisplays: Set<CGDirectDisplayID>?
    private var bridge: YCVirtualDisplayBridge?
    private var activeSession: MacVirtualDisplaySession?
    private var mirroredPhysicalDisplayID: CGDirectDisplayID?
    private var pendingDeactivation: DispatchWorkItem?
    private var pendingDeactivationID: UUID?

    init(recoveryStore: DisplayRecoveryStore = DisplayRecoveryStore()) {
        self.recoveryStore = recoveryStore
    }

    var isSupported: Bool {
        YCVirtualDisplayBridge.isSupported
    }

    var activeDisplayID: CGDirectDisplayID? {
        lock.withLock { activeSession?.displayID }
    }

    var activePhysicalDisplayID: CGDirectDisplayID? {
        lock.withLock { activeSession?.physicalDisplayID }
    }

    func activate(
        requestedPixels: StreamDimensions,
        mirroring physicalDisplayID: CGDirectDisplayID?,
        refreshRate: Double
    ) throws -> MacVirtualDisplaySession {
        guard refreshRate.isFinite, (15...120).contains(refreshRate) else {
            throw MacVirtualDisplayError.invalidDimensions
        }
        let pixels = VideoOutputSizingPolicy.normalizedRequest(requestedPixels)
        let frameRate = VideoStreamLimits.normalizedFrameRate(Int(refreshRate.rounded()))
        eventLog.record(
            "准备虚拟显示器：目标 \(pixels.width)×\(pixels.height)，物理显示器 \(physicalDisplayID.map(String.init) ?? "无，使用独立桌面")，刷新率 \(frameRate)"
        )
        guard pixels.width.isMultiple(of: 2),
              pixels.height.isMultiple(of: 2) else {
            eventLog.record("拒绝虚拟显示器请求：目标尺寸不是正偶数")
            throw MacVirtualDisplayError.invalidDimensions
        }
        guard physicalDisplayID != kCGNullDirectDisplay else {
            eventLog.record("拒绝虚拟显示器请求：物理显示器编号无效")
            throw MacVirtualDisplayError.invalidPhysicalDisplay
        }
        do { try MacDisplayRouting.requireDisplaysNotOccupied() } catch {
            eventLog.record("拒绝虚拟显示器请求：\(error.localizedDescription)")
            throw error
        }

        return try lock.withLock {
            let targetPhysicalDisplayID: CGDirectDisplayID?
            if let activeSession,
               physicalDisplayID == activeSession.displayID,
               let mirroredPhysicalDisplayID {
                targetPhysicalDisplayID = mirroredPhysicalDisplayID
                eventLog.record(
                    "检测到虚拟屏被误选为物理屏，继续使用原物理显示器 \(mirroredPhysicalDisplayID)"
                )
            } else {
                targetPhysicalDisplayID = physicalDisplayID
            }
            pendingDeactivation?.cancel()
            pendingDeactivation = nil
            pendingDeactivationID = nil
            if bridge != nil,
               activeSession?.pixelDimensions == pixels,
               activeSession?.frameRate == frameRate,
               let current = activeSession {
                if mirroredPhysicalDisplayID != targetPhysicalDisplayID {
                    _ = try restorePendingOnLock()
                    if let targetPhysicalDisplayID {
                        guard !recoveryStore.exists else { throw DisplayRecoveryError.unavailable }
                        let snapshot = try DisplayConfigurationSnapshot.capture()
                        try recoveryStore.save(DisplayRecoveryRecord(snapshot: DisplayConfigurationSnapshot(
                            entries: snapshot.entries.filter { $0.id != current.displayID })))
                        try bridge!.mirrorPhysicalDisplay(targetPhysicalDisplayID)
                    }
                    mirroredPhysicalDisplayID = targetPhysicalDisplayID
                    activeSession = MacVirtualDisplaySession(displayID: current.displayID,
                        physicalDisplayID: targetPhysicalDisplayID, pixelDimensions: pixels, frameRate: frameRate)
                    captureRecovery.reset()
                }
                guard let activeSession else { throw MacVirtualDisplayError.invalidPhysicalDisplay }
                eventLog.record(
                    "复用虚拟显示器：\(Self.displayState(activeSession.displayID))；物理屏：\(Self.displayState(targetPhysicalDisplayID))"
                )
                return activeSession
            }

            if let activeSession {
                eventLog.record("目标发生变化，释放旧虚拟显示器：\(Self.displayState(activeSession.displayID))")
            }
            try releaseOnLock()
            if recoveryStore.exists, targetPhysicalDisplayID != nil { throw DisplayRecoveryError.unavailable }
            // 独立桌面只创建自己的虚拟屏，不修改物理屏，也不保存虚假的恢复记录。
            if targetPhysicalDisplayID != nil {
                let snapshot = try DisplayConfigurationSnapshot.capture()
                try recoveryStore.save(DisplayRecoveryRecord(snapshot: snapshot))
            }

            let createdBridge: YCVirtualDisplayBridge
            do {
                createdBridge = try YCVirtualDisplayBridge(
                    pixelWidth: UInt(pixels.width),
                    pixelHeight: UInt(pixels.height),
                    refreshRate: Double(frameRate)
                )
                eventLog.record("虚拟显示器创建完成：\(Self.displayState(createdBridge.displayID))")
            } catch {
                eventLog.record("虚拟显示器创建失败：\(error.localizedDescription)")
                try releaseOnLock()
                throw error
            }
            bridge = createdBridge
            do {
                if let targetPhysicalDisplayID {
                    try createdBridge.mirrorPhysicalDisplay(targetPhysicalDisplayID)
                }
            } catch {
                eventLog.record(
                    "显示器镜像失败：虚拟屏 \(createdBridge.displayID)，物理屏 \(targetPhysicalDisplayID.map(String.init) ?? "无")，原因：\(error.localizedDescription)"
                )
                try releaseOnLock()
                throw error
            }
            let session = MacVirtualDisplaySession(
                displayID: createdBridge.displayID,
                physicalDisplayID: targetPhysicalDisplayID,
                pixelDimensions: pixels,
                frameRate: frameRate
            )
            bridge = createdBridge
            activeSession = session
            captureRecovery.reset()
            try recordPhysicalTopologyOnLock()
            mirroredPhysicalDisplayID = targetPhysicalDisplayID
            eventLog.record(
                "虚拟显示器就绪：\(Self.displayState(session.displayID))；物理屏：\(Self.displayState(targetPhysicalDisplayID))"
            )
            return session
        }
    }

    func physicalDisplays() throws -> [CGDirectDisplayID] {
        let owned = activeDisplayID
        try MacDisplayRouting.requireDisplaysNotOccupied()
        return try MacDisplayRouting.onlineDisplays().filter {
            $0 != owned && !MacDisplayRouting.isNonPhysicalDisplay($0)
        }
    }

    func arrange(placement: RemoteDisplayPlacement) throws {
        try lock.withLock {
            guard let session = activeSession, session.physicalDisplayID == nil else { return }
            let physical = try MacDisplayRouting.onlineDisplays().filter {
                $0 != session.displayID && !MacDisplayRouting.isNonPhysicalDisplay($0)
            }
            if !physical.isEmpty {
                try MacDisplayLayout.apply(display: session.displayID, physical: physical, placement: placement)
            }
        }
    }

    func confirmedState(placement: RemoteDisplayPlacement) throws -> RemoteDisplayState {
        try lock.withLock {
            let online = try MacDisplayRouting.onlineDisplays()
            guard let session = activeSession, online.contains(session.displayID) else {
                throw MacDisplayLayout.LayoutError.inconsistentState
            }
            let physical = online.filter {
                $0 != session.displayID && !MacDisplayRouting.isNonPhysicalDisplay($0)
            }
            if let target = session.physicalDisplayID {
                guard physical.contains(target), CGDisplayMirrorsDisplay(target) == session.displayID else {
                    throw MacDisplayLayout.LayoutError.inconsistentState
                }
                return RemoteDisplayState(mode: .mirror)
            }
            guard CGDisplayMirrorsDisplay(session.displayID) == kCGNullDirectDisplay else {
                throw MacDisplayLayout.LayoutError.inconsistentState
            }
            if physical.isEmpty { return RemoteDisplayState(mode: .standalone) }
            let expected = try MacDisplayLayout.origin(size: CGDisplayBounds(session.displayID).size,
                physicalBounds: physical.map { CGDisplayBounds($0) }, placement: placement)
            guard CGDisplayBounds(session.displayID).origin == expected else {
                throw MacDisplayLayout.LayoutError.inconsistentState
            }
            return RemoteDisplayState(mode: .extended, placement: placement)
        }
    }

    func deactivate() {
        do {
            try lock.withLock {
                pendingDeactivation?.cancel()
                pendingDeactivation = nil
                pendingDeactivationID = nil
                try releaseOnLock()
            }
        } catch { reportRestorationFailure(error) }
    }

    private func restorePendingOnLock() throws -> DisplayRecoveryRestorer.Result {
        let result = try DisplayRecoveryRestorer(store: recoveryStore).restoreAvailable()
        switch result {
        case .restored:
            if activeSession != nil, mirroredPhysicalDisplayID == nil { captureRecovery.displayChanged() }
            eventLog.recordChange("已自动恢复原显示器配置", key: "恢复状态")
            onRestored?()
        case .waitingForHardware:
            eventLog.recordChange("原显示器已拔出，保留配置等待重插，独立虚拟桌面仍可使用", key: "恢复状态")
        case .nothingToRestore:
            break
        }
        return result
    }

    private func releaseOnLock() throws {
        _ = try restorePendingOnLock()
        bridge?.invalidate()
        bridge = nil
        activeSession = nil
        observedPhysicalDisplays = nil
        mirroredPhysicalDisplayID = nil
        captureRecovery.reset()
    }

    // 保持虚拟屏对象和编号，拔线不等同于结束远程会话。
    private func detachOfflinePhysicalDisplayOnLock() throws {
        guard let session = activeSession, let physical = session.physicalDisplayID,
              !(try MacDisplayRouting.onlineDisplays()).contains(physical) else { return }
        activeSession = MacVirtualDisplaySession(displayID: session.displayID, physicalDisplayID: nil,
                                                pixelDimensions: session.pixelDimensions, frameRate: session.frameRate)
        mirroredPhysicalDisplayID = nil
        captureRecovery.displayChanged()
        eventLog.record("物理显示器已拔出，继续使用虚拟桌面 \(session.displayID)，保留原配置等待重插")
    }

    private func recordPhysicalTopologyOnLock() throws {
        guard let session = activeSession else { return }
        let current = Set(try MacDisplayRouting.onlineDisplays().filter {
            $0 != session.displayID && !MacDisplayRouting.isNonPhysicalDisplay($0)
        })
        if let previous = observedPhysicalDisplays, previous != current {
            captureRecovery.displayChanged()
            eventLog.record("物理显示器拓扑已变化，保留虚拟屏并允许恢复采集")
        }
        observedPhysicalDisplays = current
    }

    func reconcileDisplays() throws {
        try lock.withLock {
            try detachOfflinePhysicalDisplayOnLock()
            try recordPhysicalTopologyOnLock()
            if activeSession?.physicalDisplayID == nil { _ = try restorePendingOnLock() }
        }
    }

    func consumeCaptureRestartAfterDisplayChange() throws -> Bool {
        try lock.withLock {
            try detachOfflinePhysicalDisplayOnLock()
            try recordPhysicalTopologyOnLock()
            return captureRecovery.consume()
        }
    }

    func restoreSavedConfiguration() throws {
        try lock.withLock {
            pendingDeactivation?.cancel()
            pendingDeactivation = nil
            pendingDeactivationID = nil
            // 显式恢复必须完整成功；原硬件缺失时告知用户，不能宣称已恢复。
            if recoveryStore.exists {
                guard try restorePendingOnLock() == .restored else { throw DisplayRecoveryError.unavailable }
            } else if bridge == nil { throw DisplayRecoveryError.missingRecord }
            try releaseOnLock()
        }
    }

    private func reportRestorationFailure(_ error: Error) {
        let status = "恢复 Mac 显示器配置失败：\(error.localizedDescription)"
        eventLog.record(status)
        onFailure?(status)
    }

    func deactivate(after delay: TimeInterval) {
        let deactivationID = UUID()
        let workItem = DispatchWorkItem { [weak self] in
            self?.deactivateIfStillScheduled(id: deactivationID)
        }
        lock.withLock {
            pendingDeactivation?.cancel()
            pendingDeactivation = workItem
            pendingDeactivationID = deactivationID
            if let activeSession {
                eventLog.record(
                    "计划在 \(String(format: "%.1f", delay)) 秒后释放虚拟显示器 \(activeSession.displayID)"
                )
            }
        }
        cleanupQueue.asyncAfter(deadline: .now() + max(0, delay), execute: workItem)
    }

    private func deactivateIfStillScheduled(id deactivationID: UUID) {
        do {
            try lock.withLock {
                guard pendingDeactivationID == deactivationID,
                      let pendingDeactivation, !pendingDeactivation.isCancelled else { return }
                self.pendingDeactivation = nil
                pendingDeactivationID = nil
                try releaseOnLock()
            }
        } catch { reportRestorationFailure(error) }
    }

    deinit {
        pendingDeactivation?.cancel()
        do { try releaseOnLock() }
        catch { eventLog.record("退出时恢复显示器失败：\(error.localizedDescription)") }
    }

    private static func displayState(_ displayID: CGDirectDisplayID?) -> String {
        guard let displayID else { return "无，使用独立虚拟桌面" }
        let mode = CGDisplayCopyDisplayMode(displayID)
        let modeText = mode.map {
            "\($0.width)×\($0.height) 点，\($0.pixelWidth)×\($0.pixelHeight) 像素，\(Int($0.refreshRate.rounded())) Hz"
        } ?? "无活动模式"
        return "编号 \(displayID)，\(modeText)，在线 \(CGDisplayIsOnline(displayID) != 0)，活动 \(CGDisplayIsActive(displayID) != 0)，休眠 \(CGDisplayIsAsleep(displayID) != 0)，镜像 \(CGDisplayIsInMirrorSet(displayID) != 0)，镜像源 \(CGDisplayMirrorsDisplay(displayID))"
    }
}

private enum MacVirtualDisplayError: LocalizedError {
    case invalidDimensions
    case invalidPhysicalDisplay

    var errorDescription: String? {
        switch self {
        case .invalidDimensions:
            return "iPad 请求的虚拟显示尺寸无效"
        case .invalidPhysicalDisplay:
            return "没有可镜像的 Mac 显示器"
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
