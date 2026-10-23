# 息屏后开始回传黑屏修复

2026-09-10

## 本次证据

用户照片显示回传区域黑屏，点击鼠标后恢复。上次仅修复显示层交接与起始关键帧组装，没有处理已息屏桌面的主动唤醒。

旧 Mac 日志中，请求 9742C642-2E72-4E87-AD98-F85595DE9FC3 的首个完整采集帧亮度抽样为 0–0，编码关键帧只有 975 字节。同请求在 iPad 的 246 ms 完成解码、263 ms 显示层可显示。这次证据说明黑画面已经来自 Mac 采集源，不能把显示层可显示当作桌面内容正常的证明。

旧逻辑只有 PreventUserIdleDisplaySleep，防止之后自动息屏，不会点亮已经熄灭的显示器。Apple 明确说明需要唤醒时使用 IOPMAssertionDeclareUserActivity：
https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventuseridledisplaysleep

## 修改

Mac 在已授权、参数通过校验的回传请求中，建立电源保护和虚拟显示器、完成布局之后，采集之前调用显示唤醒。每次会话只申请一次用户活动断言，停止时释放；系统超时销毁的断言按已结束处理。唤醒失败返回现有启动错误路径。没有注入鼠标点击，没有更改系统息屏配置。

修改文件：
- Mac/YingchuiMac/Power/MacStreamPowerActivity.swift
- Mac/YingchuiMac/Host/MacStreaming.swift
- Mac/YingchuiMacTests/StreamPowerTests.swift

## 实机验证

测试设备为当前 Mac 与 iPad Air 3，实际运行独立虚拟桌面。通过 pmset displaysleepnow 先息屏，再由 iPad 自动发起回传；测试没有发送鼠标或键盘事件，没有申请截图权限。

1. 新建虚拟显示器，Mac 请求 F62ED53C-0913-4A84-AB69-FB1C090D71C1：首帧亮度范围 11–255，首关键帧 178592 字节。iPad 1285 ms 解码、1416 ms 显示层可显示，随后持续解码超过 1800 帧。
2. 复用虚拟显示器，请求 8F812ED6-9CFB-4AD0-9257-80BB09EFC9B6：开始时日志明确记录“活动 false，休眠 true”。显示唤醒后首帧亮度范围 11–255，关键帧 189841 字节；iPad 501 ms 解码、630 ms 显示层可显示，随后持续解码超过 1300 帧。

亮度抽样只用于确认真实采集源不再全黑，不等同于人工观察屏幕内容；显示时间取系统通知，不是屏幕发光测量。启动仍有少量普通帧丢失，已恢复，未观察到持续黑屏。

8 项电源测试通过，包含系统真实断言、一次会话只唤醒一次、未开始回传禁止唤醒、唤醒失败、释放和重试。最终内存所有权清理后复跑同组测试。

日志：work/repair/idle-black/。旧证据：work/repair/direct-touch/mac-live.log、work/repair/stable-menu/normal-launch.log。
