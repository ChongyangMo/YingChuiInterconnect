import Darwin
import Foundation
import OSLog

/// 双端共用进程监听，不接管崩溃信号；异常终止仍由系统生成原始报告。
public final class RuntimeDiagnostics: @unchecked Sendable {
    public static let shared = RuntimeDiagnostics()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.yingchui.runtime-monitor", qos: .utility)
    private let logger = Logger(subsystem: "com.yingchui.runtime", category: "进程监听")
    private var journal: RuntimeJournal?
    private var session: RuntimeJournal.Session?
    private var timer: DispatchSourceTimer?
    private var pressure: DispatchSourceMemoryPressure?
    private var lastResources: ProcessResourceSnapshot?

    public func start() {
        lock.withLock {
            guard session == nil else { return }
            do {
                let support = try FileManager.default.url(for: .applicationSupportDirectory,
                    in: .userDomainMask, appropriateFor: nil, create: true)
                guard let identifier = Bundle.main.bundleIdentifier else {
                    throw NSError(domain: "进程监听缺少应用标识", code: 1)
                }
                let journal = try RuntimeJournal(directory: support.appendingPathComponent(identifier)
                    .appendingPathComponent("Diagnostics"))
                let previous = try journal.previousSession()
                let now = Date()
                let current = RuntimeJournal.Session(id: UUID(), processID: getpid(), startedAt: now,
                    lastSeenAt: now, phase: "启动", endedNormally: false)
                if let previous, !previous.endedNormally {
                    try journal.append("上次运行未记录正常退出：进程 \(previous.processID)，最后活动 \(previous.lastSeenAt)，状态 \(previous.phase)；需要结合系统崩溃报告判断，后台回收也可能不通知退出")
                }
                try journal.append("进程启动：会话 \(current.id)，进程 \(getpid())，父进程 \(getppid())，终端连接 \(isatty(STDOUT_FILENO) == 1)，系统 \(ProcessInfo.processInfo.operatingSystemVersionString)")
                try journal.checkpoint(current)
                try journal.synchronize()
                self.journal = journal
                session = current
                logger.notice("进程监听已启用：\(journal.directory.path, privacy: .public)")
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: 30, leeway: .seconds(2))
                timer.setEventHandler { [weak self] in self?.heartbeat() }
                self.timer = timer
                timer.resume()
                let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
                pressure.setEventHandler { [weak self] in self?.recordPressure() }
                self.pressure = pressure
                pressure.resume()
            } catch { report(error) }
        }
    }

    public func record(_ message: String, category: String) {
        lock.withLock {
            guard let journal else { return }
            do { try journal.append("[\(category)] \(message)") }
            catch { report(error) }
        }
    }

    public func phase(_ phase: String, endingNormally: Bool = false) {
        lock.withLock {
            guard let journal, var current = session else { return }
            do {
                current.phase = phase
                current.lastSeenAt = Date()
                current.endedNormally = endingNormally
                try journal.append("进程状态：\(phase)，已运行 \(Int(current.lastSeenAt.timeIntervalSince(current.startedAt))) 秒")
                try journal.checkpoint(current)
                try journal.synchronize()
                session = current
                if endingNormally { timer?.cancel(); pressure?.cancel() }
            } catch { report(error) }
        }
    }

    private func heartbeat() {
        lock.withLock {
            guard let journal, var current = session, !current.endedNormally else { return }
            do {
                let sample = try ProcessResourceSnapshot.read()
                let cpu: String
                if let previous = lastResources, sample.uptime > previous.uptime {
                    cpu = String(format: "%.1f%%", 100 * (sample.cpuSeconds - previous.cpuSeconds) / (sample.uptime - previous.uptime))
                } else { cpu = "首个样本" }
                lastResources = sample
                current.lastSeenAt = Date()
                try journal.append(String(format: "运行采样：进程 %d，内存 %.1f MB，CPU %@，状态 %@，运行 %d 秒",
                    current.processID, Double(sample.memoryBytes) / 1_048_576, cpu, current.phase,
                    Int(current.lastSeenAt.timeIntervalSince(current.startedAt))))
                try journal.checkpoint(current)
                try journal.synchronize()
                session = current
            } catch { report(error) }
        }
    }

    private func recordPressure() {
        lock.withLock {
            guard let pressure, let journal else { return }
            let level = pressure.data.contains(.critical) ? "严重" : pressure.data.contains(.warning) ? "警告" : "恢复正常"
            do { try journal.append("系统内存压力：\(level)"); try journal.synchronize() }
            catch { report(error) }
        }
    }

    private func report(_ error: Error) {
        logger.fault("运行监听记录失败：\(error.localizedDescription, privacy: .public)")
    }
}
