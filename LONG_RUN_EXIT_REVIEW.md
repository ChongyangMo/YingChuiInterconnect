# 长时间运行退出调查

调查时间：2026-09-10 11:59–12:05，中国标准时间。

## 确认事实

- Mac 进程 YingchuiMac，PID 40694，于 2026-09-10 11:56:44.063 退出。该进程是 01:07 左右通过调试终端中 script 启动的版本，运行约 10 小时 49 分钟。
- 最后一次编码服务运行 16251.603 秒，约 4 小时 31 分钟。退出前一秒仍在编码和发送，约 54.37 fps，编码耗时约 8.91 ms，没有先出现编码停滞。
- LaunchServices 记录 LSExitStatus=0。该信息不能独立证明退出触发者，更不能据此断言一定是用户主动退出。
- 检查用户级、系统级 Mac DiagnosticReports，以及连接 iPad 的 systemCrashLogs，没有找到本次 Yingchui 崩溃报告。目标时间段未检出相关内存终止记录。不能以缺少报告排除所有异常退出。
- iPad 进程 PID 1788 仍存在，属于先前安装的同一应用；未发现本次 iPad 崩溃证据。停止前日志显示解码累计 222373 帧，累计丢帧 6，声音缓冲最后 40 ms。
- 调试应用在 11:56:42 左右发生任务切换/恢复，与 Mac 退出时间接近；现有日志没有记录向 PID 40694 发送的终止信号，时间相关不能证明因果。

## 处置

已通过 /usr/bin/open 将原有、已编译的 Mac 应用独立启动，由系统 LaunchServices 管理。验证新 PID 63890 的 PPID=1、TTY=??，不再由 script 或工具终端托管。没有修改系统登录项或添加永久守护任务，也没有根据尚未确认的猜测修改视频代码。

这消除了此前长期运行依附调试终端的风险；本次退出的精确触发原因尚未确认。已向用户询问当时是否触发退出快捷键或关闭调试任务，回答到达后可继续对照。

## 证据

work/repair/long-run-exit/mac-system.log：目标时间段进程与退出记录。
work/repair/long-run-exit/exit-context.log：退出前编码状态和系统服务清理。
work/repair/long-run-exit/quit-detail.log：更窄时间段的应用与 Apple Events 记录。
work/repair/long-run-exit/pad-crash-index.json：iPad 系统崩溃报告索引。
work/repair/long-run-exit/pad-processes.json：iPad 进程快照。
work/repair/idle-black/mac-normal-live.log、pad-normal-launch.log：此前长期运行输出。

下一次如再次发生，应优先保留退出时间和设备崩溃报告。现阶段没有证据将此事件归因为长时间运行导致的内存泄漏。
