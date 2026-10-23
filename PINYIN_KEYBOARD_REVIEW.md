# Mac 原生拼音（2026-09-09）

用户选择在 Mac 光标旁显示候选词，复用 Mac 原生中文输入法。

- 悬浮键盘新增中/英模式切换，中文选择 Mac 已启用的简体拼音，英文选择 ABC。缺少对应输入法或系统切换失败时明确报告错误。
- 中文模式将拉丁字母、数字和标点转换为真实 Mac 按键，交由输入法组词；空格、数字、删除、回车保留原生候选选择行为。已经由 iPad 系统输入法确认的中文和表情仍按 Unicode 提交。
- 输入法切换等待匹配的 Mac 回执，切换期间禁用文字键，错误与超时不会把界面伪装成已切换。重连清理未完成请求。
- 原有 iPad 系统输入法移到键盘菜单；透明、拖动、实时输入与实体按键反馈保留。
- 控制协议升级到 8，增加输入法切换消息并补齐字母、数字、标点按键。Mac 和 iPad 需配套升级，配对信息与 TLS 身份不变。

验证：67 项共享协议测试、13 项 iPad 专项测试、2 项 Mac 测试通过。Mac 测试在临时 NSTextView 中实际发送 nihao，验证原生组词、空格确认中文与切回英文；测试后恢复原输入法。iPad TCP 测试验证拼音与数字按物理按键顺序发送，回执测试验证成功确认与无效回执处理。

两端 Debug 编译、Release 编译与静态分析通过。新 Mac 程序已更新到原 Xcode Debug 路径；旧程序备份在 work/repair/YingchuiMac-before-pinyin.app。显示恢复记录原样保留，没有删除或绕过恢复检查。

日志：work/repair/mac-pinyin-focus-tests.log、pad-pinyin-tests.log、pinyin-protocol-tests.log、mac-pinyin-release.log、pad-pinyin-release.log、pinyin-physical.log。

最终实机验证完成：简体拼音、ABC 两次切换均收到 Mac 确认；连续开合悬浮键盘三次，关闭时累计解码 335、736、1136 帧，始终保持回传。观察声音队列约 35–65 毫秒，没有积压上限错误。日志：work/repair/pinyin-physical-final.log。首轮自动开合脚本因全屏启动时任务取消未完成，已修正脚本提前消耗运行标记的问题，再次实测三轮完成；此修正只作用于显式调试启动参数。

已恢复仅带 --diagnostic-console 的普通 iPad 启动。Mac 运行于原 Xcode Debug 路径，协议版本 8。无需重新配对；打开悬浮键盘点击“英”切换到“中”，点击字母输入拼音，空格或数字选择 Mac 候选词。
