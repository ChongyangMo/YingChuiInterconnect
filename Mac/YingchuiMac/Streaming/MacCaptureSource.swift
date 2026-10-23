import AVFoundation
import CoreMedia
import Foundation
import Network
import ScreenCaptureKit
import VideoToolbox
import YingchuiProtocol

extension MacScreenStreamer {
    func startCapture(
        displayID: CGDirectDisplayID?,
        expectedSourceSize: StreamDimensions,
        generation: UUID
    ) async {
        let startup = captureQueue.sync { startupTrace }
        do {
            try await waitForTransports(generation: generation)
            startup?.mark("音视频通道就绪")
            eventLog.record(
                "开始等待采集源：显示器 \(displayID.map { String($0) } ?? "自动")，期望 \(expectedSourceSize.width)×\(expectedSourceSize.height) 像素"
            )
            let display = try await resolveCaptureDisplay(
                displayID: displayID,
                expectedSourceSize: expectedSourceSize,
                generation: generation
            )
            startup?.mark("采集源枚举完成")
            eventLog.record(
                "已找到 ScreenCaptureKit 显示器：编号 \(display.displayID)，逻辑尺寸 \(display.width)×\(display.height)"
            )
            guard stateLock.withLock({ captureGeneration == generation }) else { return }

            let preparedStream: SCStream? = try captureQueue.sync {
                guard stateLock.withLock({ captureGeneration == generation }) else { return nil }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let displayModeSize = displayID.flatMap {
                    Self.activePixelDimensions(for: $0)
                }
                guard let nativeSourceSize = displayModeSize
                    ?? VideoOutputSizingPolicy.nativePixelDimensions(
                        pointWidth: display.width,
                        pointHeight: display.height,
                        pointPixelScale: Double(filter.pointPixelScale)
                    ) else {
                    throw StreamerError.invalidDisplayScale
                }
                let fittedSize = VideoOutputSizingPolicy.aspectFit(
                    source: nativeSourceSize,
                    within: StreamDimensions(width: outputWidth, height: outputHeight)
                )
                outputWidth = fittedSize.width
                outputHeight = fittedSize.height
                let isWiFi = usesWirelessVideo
                let maximumBitRate = outputBitRate
                let minimumBitRate = VideoBitRateFloorPolicy.minimumBitRate(
                    dimensions: fittedSize,
                    frameRate: outputFrameRate,
                    maximumBitRate: maximumBitRate,
                    constrainedNetwork: isWiFi
                )
                bitRatePolicy.reset(
                    maximumBitRate: maximumBitRate,
                    minimumBitRate: minimumBitRate,
                    initialBitRate: isWiFi ? min(maximumBitRate, 12_000_000) : maximumBitRate
                )
                outputBitRate = bitRatePolicy.currentBitRate
                self.eventLog.record(
                    "采集参数已确定：源 \(nativeSourceSize.width)×\(nativeSourceSize.height)，输出 \(outputWidth)×\(outputHeight)，\(isWiFi ? "Wi-Fi" : "当前网络")，起始码率 \(outputBitRate)，范围 \(minimumBitRate)–\(maximumBitRate) bps"
                )
                let configuration = SCStreamConfiguration()
                configuration.width = outputWidth
                configuration.height = outputHeight
                configuration.scalesToFit = true
                configuration.preservesAspectRatio = true
                configuration.captureResolution = .best
                let sourceRefreshRate = CGDisplayCopyDisplayMode(display.displayID)?.refreshRate ?? 0
                configuration.minimumFrameInterval = MacCaptureCadencePolicy.minimumInterval(
                    frameRate: outputFrameRate, displayRefreshRate: sourceRefreshRate)
                eventLog.record("采集节奏：请求 \(outputFrameRate) 帧，显示刷新率 \(sourceRefreshRate)，\(configuration.minimumFrameInterval == .zero ? "跟随显示器刷新" : "按请求限制采集")")
                // 最新画面和硬件编码会占用采集表面；留出生产余量，避免窗口动画时池耗尽。
                // 这是采集表面池容量，编码在途仍由独立准入策略限制。
                configuration.queueDepth = 5
                configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                configuration.showsCursor = !separatesCursor
                configuration.capturesAudio = capturesAudio
                configuration.sampleRate = 48_000
                configuration.channelCount = 2
                configuration.excludesCurrentProcessAudio = true

                try createNegotiatedCompressionSession()
                configuration.minimumFrameInterval = MacCaptureCadencePolicy.minimumInterval(
                    frameRate: outputFrameRate, displayRefreshRate: sourceRefreshRate)
                startup?.mark("编码器创建完成")
                let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
                if capturesAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue) }
                self.stream = stream
                startCaptureRefreshMonitor(stream: stream, filter: filter, configuration: configuration)
                return stream
            }
            guard let stream = preparedStream else { return }
            try await stream.startCapture()
            startup?.mark("采集启动完成")
            guard stateLock.withLock({ captureGeneration == generation }) else {
                do {
                    try await stream.stopCapture()
                } catch {
                    captureQueue.async { [weak self] in
                        self?.reportRuntimeError("终止过期屏幕采集失败：\(error.localizedDescription)")
                    }
                }
                return
            }
            captureQueue.async { [weak self] in
                guard let self,
                      self.stateLock.withLock({ self.captureGeneration == generation }) else { return }
                self.eventLog.record(
                    "屏幕采集已启动：\(self.outputWidth)×\(self.outputHeight) @ \(self.outputFrameRate) fps"
                )
                self.statusHandler?("正在回传 \(self.outputWidth)×\(self.outputHeight) @ \(self.outputFrameRate) fps")
            }
        } catch {
            captureQueue.async { [weak self] in
                guard let self,
                      self.stateLock.withLock({ self.captureGeneration == generation }) else { return }
                self.eventLog.record("屏幕回传启动失败：\(error.localizedDescription)")
                self.stoppedHandler?("屏幕回传启动失败：\(error.localizedDescription)", .startup)
                self.stopOnCaptureQueue()
            }
        }
    }

    func resolveCaptureDisplay(
        displayID: CGDirectDisplayID?,
        expectedSourceSize: StreamDimensions,
        generation: UUID
    ) async throws -> SCDisplay {
        var lastContentError: Error?
        for attempt in 0..<60 {
            guard stateLock.withLock({ captureGeneration == generation }) else {
                throw StreamerError.captureSuperseded
            }
            do {
                let content = try await SCShareableContent.current
                if let displayID {
                    if let display = content.displays.first(where: { $0.displayID == displayID }),
                       Self.activePixelDimensions(for: displayID) == expectedSourceSize {
                        return display
                    }
                    if Self.shouldReportCaptureWait(attempt) {
                        let available = content.displays
                            .map { "\($0.displayID):\($0.width)×\($0.height)" }
                            .joined(separator: ", ")
                        let active = Self.activePixelDimensions(for: displayID)
                        let activeText = active.map { "\($0.width)×\($0.height)" } ?? "未在线或已休眠"
                        eventLog.record(
                            "等待显示模式稳定，第 \(attempt + 1) 次：目标显示器 \(displayID)，当前像素 \(activeText)，可采集列表 [\(available)]"
                        )
                    }
                } else if let display = content.displays.first {
                    return display
                }
            } catch {
                lastContentError = error
                if Self.shouldReportCaptureWait(attempt) {
                    eventLog.record(
                        "读取 ScreenCaptureKit 显示器列表失败，第 \(attempt + 1) 次：\(error.localizedDescription)"
                    )
                }
            }

            guard attempt < 59 else { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        if let lastContentError {
            throw StreamerError.shareableContentUnavailable(lastContentError.localizedDescription)
        }
        throw StreamerError.requestedDisplayUnavailable
    }

    static func activePixelDimensions(for displayID: CGDirectDisplayID) -> StreamDimensions? {
        guard CGDisplayIsOnline(displayID) != 0,
              CGDisplayIsAsleep(displayID) == 0,
              let mode = CGDisplayCopyDisplayMode(displayID),
              mode.pixelWidth > 0,
              mode.pixelHeight > 0 else { return nil }
        return StreamDimensions(width: mode.pixelWidth, height: mode.pixelHeight)
    }

    static func shouldReportCaptureWait(_ attempt: Int) -> Bool {
        attempt == 0 || attempt == 9 || attempt == 29 || attempt == 59
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let stoppedStreamID = ObjectIdentifier(stream)
        let message = "屏幕采集已停止：\(error.localizedDescription)"
        captureQueue.async { [weak self] in
            guard let self,
                  let activeStream = self.stream,
                  ObjectIdentifier(activeStream) == stoppedStreamID else { return }
            self.eventLog.record(message)
            self.stoppedHandler?(message, .capture)
            self.stopOnCaptureQueue()
        }
    }

}
