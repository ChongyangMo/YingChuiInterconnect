# 拔线导致 Mac 退出的修复

2026-09-08。

## 已确认的原因

本机两份崩溃报告 `YingchuiMac-2026-09-08-210800.ips` 和 `YingchuiMac-2026-09-08-213840.ips` 均记录主线程 `EXC_BREAKPOINT / SIGTRAP`。首个应用代码位置为旧版 `ContentView.swift:161` 的显示器 Picker 绑定，错误为 `Swift runtime failure: Index out of range`。

旧绑定使用 `selectedDisplayID ?? availableDisplays[0].id`。外层的“列表非空才显示 Picker”不能保护异步读取的 Binding：拔线刷新先清空列表和选择，SwiftUI 在移除控件的事务中仍读取原绑定，导致整个 Mac 进程退出。控制 TCP 随之重置，后续重连没有运行中的服务可接入。

前一轮只测试了虚拟显示器与采集层，没有覆盖这个真实界面事务，这是此前修复仍然断开的原因。

## 修改

- 显示器选择绑定改为可空值，当前编号必须仍存在于列表；空列表不读取首项、不伪造显示器。
- Picker 标签改为匹配的可空类型；未完成选择时使用原生占位项。
- 延迟到达的旧选择写入会明确报告显示器已断开，不写回失效编号。
- 新增保留旧绑定后清空列表、旧控件写入、缺失选择，以及 NSHostingView 反复插入/移除列表的布局回归测试。
- 热插拔测试退出前等待系统真正移除模拟屏，避免未完成的全局显示事务干扰下一项恢复测试。

## 验证

Mac 全量 44 项测试通过；Release 编译和静态分析通过。界面测试执行 12 次列表清空与恢复并驱动实际 SwiftUI 布局，不调用截图或请求权限。

新版 Mac Release 与实机 iPad 联调通过：2224×1668 @ 60 fps 配置下，已解码 2786 帧、渲染 2354640 个声音采样帧，最后声音待渲染 185 毫秒，Mac 进程持续运行。测试后 iPad 恢复正常发布版。

真实 HDMI/DP 线缆仍需现场再拔一次验证。此修复针对已确认的应用崩溃；iPad 日志中的 NECP UDP flow 错误尚未独立复现，不据此宣称解决了所有系统网络问题。

证据摘要：`work/repair/unplug-crash-evidence.json`。
测试日志：`work/repair/unplug-crash-full-tests-2.log`。
发布构建日志：`work/repair/unplug-crash-release.log`。
