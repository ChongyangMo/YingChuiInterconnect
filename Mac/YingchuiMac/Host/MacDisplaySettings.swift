import AppKit
import CoreGraphics
import Foundation
import Network
import Security
import ServiceManagement
import YingchuiProtocol

extension MacHostModel {
    @MainActor
    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        do {
            try LaunchAtLoginController.setEnabled(enabled)
            let state = LaunchAtLoginController.currentState
            isLaunchAtLoginEnabled = state.isSelected
            launchAtLoginStatusText = state.text
            eventLog.record("登录启动设置：\(state.text)")
            if state == .needsApproval {
                statusText = "请在系统设置的登录项中批准鹰锤互联"
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            let state = LaunchAtLoginController.currentState
            isLaunchAtLoginEnabled = state.isSelected
            launchAtLoginStatusText = "设置失败"
            statusText = "登录启动设置失败：\(error.localizedDescription)"
            let systemError = error as NSError
            eventLog.record("\(statusText)；错误域 \(systemError.domain)，代码 \(systemError.code)，应用 \(Bundle.main.bundleURL.path)")
        }
    }

    @MainActor
    func refreshRuntimeState() {
        refreshDisplays()
        refreshAccessibilityStatus()
        refreshScreenCaptureStatus()
        let launchAtLoginState = LaunchAtLoginController.currentState
        isLaunchAtLoginEnabled = launchAtLoginState.isSelected
        launchAtLoginStatusText = launchAtLoginState.text
    }

    @MainActor
    func prepareForSystemSleep() {
        networkQueue.async { [weak self] in
            self?.stopStreaming()
            self?.publishStatus("Mac 即将休眠，屏幕回传已暂停")
        }
    }

    @MainActor
    func resumeAfterSystemWake() {
        refreshRuntimeState()
        networkQueue.async { [weak self] in
            guard let self, self.wantsServiceRunning else { return }
            self.stopOnNetworkQueue(publish: false)
            self.startOnNetworkQueue()
        }
    }

    @MainActor
    func requestAccessibilityAccess() {
        isAccessibilityGranted = inputController.requestAccessibilityAccess()
        statusText = isAccessibilityGranted
            ? "辅助功能权限已授权"
            : "请在系统设置的隐私与安全性中允许辅助功能权限"
    }

    @MainActor
    func refreshAccessibilityStatus() {
        isAccessibilityGranted = inputController.isAccessibilityGranted
        if isAccessibilityGranted {
            statusText = "辅助功能权限已授权，可以接收控制"
        }
    }

    @MainActor
    func requestScreenCaptureAccess() {
        isScreenCaptureGranted = screenStreamer.requestScreenCaptureAccess()
        streamStatusText = isScreenCaptureGranted
            ? "屏幕录制权限已授权"
            : "请在系统设置的隐私与安全性中允许屏幕与系统音频录制"
    }

    @MainActor
    func refreshScreenCaptureStatus() {
        isScreenCaptureGranted = screenStreamer.isScreenCaptureGranted
        streamStatusText = isScreenCaptureGranted ? "屏幕录制权限已授权" : "仍未获得屏幕录制权限"
    }

    @MainActor
    func refreshDisplays() {
        let online: [CGDirectDisplayID]
        do { online = try MacDisplayRouting.onlineDisplays() }
        catch {
            statusText = "刷新显示器失败：\(error.localizedDescription)"
            eventLog.record(statusText)
            return
        }
        networkQueue.async { [weak self] in self?.scheduleDisplayTopologyReconciliation() }
        let previousDisplays = availableDisplays
        let screens = NSScreen.screens
        let virtualDisplayID = virtualDisplayManager.activeDisplayID
        let mirroredPhysicalDisplayID = virtualDisplayManager.activePhysicalDisplayID
        let systemDisplayText = screens.compactMap { screen -> String? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return "\(number.uint32Value):\(screen.localizedName)"
        }.joined(separator: ", ")
        eventLog.recordChange(
            "显示器列表刷新：系统 [\(systemDisplayText)]，当前选择 \(selectedDisplayID.map { String($0) } ?? "无")", key: "显示器列表"
        )
        // 镜像会话存活期间，物理屏可能从 NSScreen 活动列表消失。
        // 会话中保存的物理编号是唯一可信来源，不能被虚拟屏编号覆盖。
        if let mirroredPhysicalDisplayID, online.contains(mirroredPhysicalDisplayID) {
            if let preserved = previousDisplays.first(where: { $0.id == mirroredPhysicalDisplayID }) {
                availableDisplays = [preserved]
            }
            selectedDisplayID = mirroredPhysicalDisplayID
            selectedDisplayForStreaming.set(mirroredPhysicalDisplayID)
            eventLog.recordChange("镜像期间锁定物理显示器选择：\(mirroredPhysicalDisplayID)", key: "显示器选择")
            return
        }
        let displays = screens.compactMap { screen -> MacDisplayOption? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            guard online.contains(displayID), displayID != virtualDisplayID,
                  !MacDisplayRouting.isNonPhysicalDisplay(displayID),
                  screen.localizedName != MacVirtualDisplayManager.displayName else {
                return nil
            }
            let scale = screen.backingScaleFactor
            let width = Int(screen.frame.width * scale)
            let height = Int(screen.frame.height * scale)
            return MacDisplayOption(
                id: displayID,
                name: screen.localizedName,
                resolution: "\(width)×\(height)"
            )
        }
        // 已在上面保留真实在线的镜像成员；零块显示器时清除拔线前的旧选择。
        guard !displays.isEmpty else {
            availableDisplays = []
            selectedDisplayID = nil
            selectedDisplayForStreaming.set(nil)
            eventLog.recordChange("未连接物理显示器，回传时使用独立虚拟桌面", key: "显示器选择")
            return
        }
        availableDisplays = displays
        if let preferredDisplayID,
           displays.contains(where: { $0.id == preferredDisplayID }) {
            selectedDisplayID = preferredDisplayID
        } else if selectedDisplayID == nil || !displays.contains(where: { $0.id == selectedDisplayID }) {
            selectedDisplayID = displays.first?.id
        }
        selectedDisplayForStreaming.set(selectedDisplayID)
        eventLog.recordChange("物理显示器选择已更新：\(selectedDisplayID.map { String($0) } ?? "无")", key: "显示器选择")
    }

    @MainActor
    func selectDisplay(_ displayID: CGDirectDisplayID) {
        guard availableDisplays.contains(where: { $0.id == displayID }) else {
            streamStatusText = "所选显示器已断开，请重新选择"
            eventLog.record(streamStatusText)
            return
        }
        preferredDisplayID = displayID
        selectedDisplayID = displayID
        selectedDisplayForStreaming.set(displayID)
        UserDefaults.standard.set(displayID, forKey: Self.selectedDisplayKey)
        streamStatusText = "已选择显示器，下一次回传生效"
    }
}
