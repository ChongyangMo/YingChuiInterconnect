# 双端运行监听日志

2026-09-10

## 保存内容

- 进程启动、会话编号、PID、父进程、是否连接终端、系统版本。
- 每 30 秒记录物理内存占用、区间 CPU 占用、应用状态及运行时长。CPU 按单核 100% 计算，多核任务可高于 100%。
- 系统内存压力、iPad 内存警告、前后台切换。
- Mac 正常退出请求及退出通知；iPad 系统退出通知。
- 现有 DiagnosticEventLog 的连接、采集、编解码、电源、恢复事件统一保存。
- session.json 原子保存最近运行状态。下次启动发现未正常结束时记录提示，不直接判定崩溃；iOS 后台回收和强制结束也可能不发送退出通知。

不安装信号处理器、不修改系统崩溃报告机制；SIGKILL 等无法由应用写出最后一条日志，需对照系统报告。最后资源采样最多约 30 秒前（后台挂起时可能更早）。

## 文件位置与容量

Mac：~/Library/Application Support/com.yingchui.interconnect.mac/Diagnostics/

iPad：应用数据容器的 Library/Application Support/com.yingchui.interconnect.pad/Diagnostics/

runtime.log、runtime.1.log、runtime.2.log，每份最多约 2 MB，合计约 6 MB；单条记录过长会附明确截断标记。采样、状态改变和退出时同步文件；session.json 保存最后会话状态。写入错误会通过系统日志 fault 明确报告，不伪造日志成功。

日志包含 ISO 8601 UTC 时间，可与系统日志对齐。没有加入按键正文、密码或令牌记录。

## 实现

共享 Diagnostics 目录拆分 RuntimeJournal（文件与轮换）、ProcessResourceSnapshot（系统资源）、RuntimeDiagnostics（监听与生命周期）。双端分别接入轻量 delegate；iPad 前后台使用 SwiftUI scenePhase，以兼容 UIScene 生命周期。

## 验证与部署

- 4 项共享测试通过：文件轮换容量、跨实例会话状态恢复、损坏记录明确报错、真实进程资源读取。
- Mac / iPad 真机 Debug 编译成功。
- Mac 实际启动、30/60 秒资源采样、系统退出请求、正常退出标记、重新启动均落盘验证通过。
- iPad 实机安装和启动成功，已从设备复制日志验证启动、前台状态、连接事件和周期资源采样。
- 两端正常启动均记录父进程 1、终端连接 false。监听不需要调试控制台保持打开。

验证输出：work/repair/runtime-monitor/。
