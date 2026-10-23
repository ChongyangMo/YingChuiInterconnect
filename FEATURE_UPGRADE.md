# 鹰锤互联功能升级与验证

最新声音队列及视频冷启动修复见 `AUDIO_QUEUE_FIX.md`：Mac 20 项、iPad 真机 55 项测试通过，原生画质下真实声画连续回传两分钟通过。

日期：2026-09-08。九项功能已实现并完成自动验证。后续已修复旧配对索引迁移缺陷，真机可以连接 Mac 并进入正常配对；见 `PAIRING_MIGRATION_FIX.md`。下文的旧凭据阻断与清空建议属于修复前记录，不再作为当前操作步骤。

## 已实现

| 功能 | 使用方式与行为 |
| --- | --- |
| 快捷连接 | 连接页“连接上次 Mac”；记住成功配对的主机 UUID，首帧解码成功后自动全屏。主机离线明确提示。 |
| 全屏软件键盘 | “更多 → 键盘”；中文组合输入、密码输入、Esc、Tab、删除、回车与 Command 快捷键。长文字分段传送，显示执行回执或失败。 |
| 显示配置恢复 | Mac 在修改显示配置前原子保存恢复文件；正常恢复成功后删除。异常退出后检测遗留记录，主界面和菜单栏提供“恢复显示器”。无法匹配原屏幕和显示模式时保留记录并报错。 |
| 全屏错误与重试 | 全屏内显示断线或播放错误，提供重试按钮。 |
| 可信设备管理 | Mac 查看已配对设备，显示连接和控制状态；可单独撤销。先保存凭据变更，再撤销会话；存储失败保留原授权。同一时刻只允许一个控制会话。 |
| 诊断导出 | “更多 → 导出诊断”；复用已有诊断摘要和事件记录。 |
| 在线画质切换 | 连接页和全屏“更多 → 画质”均可切换，保持连接并重新协商视频。 |
| 双向文字剪贴板 | “更多 → 发送剪贴板到 Mac / 复制 Mac 剪贴板”；仅用户主动触发，通过 TLS 传送；限制 64 KiB，空内容、超时和写入失败明确提示。 |
| Mac 系统声音 | “更多 → 声音”；ScreenCaptureKit 采集系统声音，独立认证加密 UDP，48 kHz 双声道 PCM；首个合法来源绑定，过期包不播放，队列有上限；不采集麦克风。 |

界面保留极简结构，没有恢复“控制与输入”“连接与诊断”两个展开栏。新功能拆分到 Features、Audio、Connection 和 VirtualDisplay；iPad 连接模型主体为 275 行。

协议升级到 7，两端必须同时更新。有效的现有 UUID 凭据继续使用；无效记录不会被静默清空。没有使用 Git 或新增环境变量配置。

## 验证结果

| 验证 | 结果 |
| --- | --- |
| 共享协议 | 53 项通过 |
| Mac 应用 | 17 项通过 |
| iPad 模拟器 | 42 项通过 |
| iPad Air 3 真机，iPadOS 17.7 | 同一套 42 项再次通过 |
| Mac Release 构建与静态分析 | 通过 |
| iPad 模拟器 Release 构建与静态分析 | 通过 |
| iPad 真机 Release 构建与静态分析 | 通过 |
| 实际新版 Mac TLS 握手 | 协议 7、请求编号、未配对拒绝授权均通过 |
| 实际 iPad 启动与发现 | 可以发现新版 Mac；旧凭据校验明确失败 |
| iPad 发布版安装 | 已安装到连接的 iPad |

共 112 个不同测试，iPad 的 42 项另外在真机重复执行。声音测试覆盖 PCM 转换、加密数据包、真实 UDP 来源绑定及 AVAudioEngine 播放完成回调；播放测试使用静音数据，不代表已验收真实系统声音的听感与音画同步。

本轮修正了 Swift 编译器对界面绑定方法引用的崩溃、快捷连接重复启动接收端、部分文字失败被后续成功回执覆盖，以及音频会话启动失败后的资源清理。

验证日志：

- 全套自动验证：`work/validation/20260908-164757/`
- 真机最终测试：`work/repair/features-device-final-tests.log`
- 真机发布构建与分析：`work/repair/features-device-release.log`
- 实际握手：`work/repair/features-live-handshake.log`
- 真机启动：`work/repair/features-ipad-runtime.log`
- 发布版安装：`work/repair/features-device-install.log`

自动验证可用 `python3 Tools/validate.py` 重现，任务配置在 `validation.json`。本轮只有 Xcode 的无 AppIntents 依赖元数据提示，没有编译错误或静态分析发现。

## 需要人在设备上完成

当前 iPad 报错：**配对凭据读取失败：配对主机编号无效**。

1. 打开 iPad 上的鹰锤互联，点“重置全部信任”。
2. 确认“清除全部配对信息”。这会清除该 iPad 保存的全部 Mac 配对记录。
3. 选择新版 Mac，输入 Mac 上显示的六位配对码。
4. 若系统要求，在 Mac 授予辅助功能、屏幕与系统音频录制权限；iPad 允许局域网访问。

此前界面自动操作权限被拒绝；本轮没有绕过该权限代点重置对话框，也没有直接删除钥匙串记录。

完成重新配对后仍需验收：真实系统声音与音画同步、中文和密码在目标应用中的输入、双向实际剪贴板、播放中画质切换，以及复杂多屏异常退出后的恢复。自动测试不能替代这些整机验收。软件键盘使用系统 Unicode 键盘事件，部分目标应用可能采用自己的按键翻译方式，见 [Apple 的键盘事件说明](https://developer.apple.com/documentation/coregraphics/cgevent/keyboardsetunicodestring%28stringlength%3Aunicodestring%3A%29)。

## 构建产物

- Mac：`work/repair/mac-build/Build/Products/Release/YingchuiMac.app`
- iPad：`work/repair/device-release/Build/Products/Release-iphoneos/YingchuiPad.app`

新版 Mac 已启动，iPad 发布版已安装。Mac 正式对外分发的签名、公证与装订不在本轮九项功能范围内。
