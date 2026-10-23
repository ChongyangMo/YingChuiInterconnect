# iPad 更多菜单稳定性修复

2026-09-10

## 发现

原来的 SwiftUI Menu、显示模式子菜单和开发者动作直接订阅 PadConnectionModel。视频统计和连接状态更新会重新计算菜单内容；首帧之后，解码回调还在每帧重复给 @Published videoIsPlaying 赋值 true，放大了刷新频率。这是菜单反复更新的代码路径；没有对旧版本录屏复现。

## 修改

- 三个点使用稳定的 UIButton 和原生 UIMenu。只创建一次根菜单，使用 UIDeferredMenuElement.uncached 在每次打开时同步生成完整菜单快照。SwiftUI 更新仅替换下次打开使用的数据提供闭包，不替换展开中的菜单。
- 操作方式、显示模式、屏幕位置、画质均使用原生嵌套菜单；保留声音、键盘、剪贴板、开发者动作与退出全屏。
- 开发者设置和选中项每次打开重新读取；导出诊断保留系统分享面板。
- 保留 44×44 点击区域、蓝色半透明全屏按钮及增强对比度适配。
- 首帧之后不再重复发布 videoIsPlaying = true。

原生延迟菜单行为参考：https://developer.apple.com/documentation/uikit/uideferredmenuelement

## 验证

- iPad 真机 Debug 编译成功。
- iOS 26.5 模拟器：菜单 3 项测试、工具栏布局 1 项测试通过；随后加强实际菜单展开测试，3 项菜单测试再次通过。
- 连接的 iPad Air 3（iPadOS 17.7）：3 项菜单测试全部通过。自动调用公开的 performPrimaryAction 实际打开原生菜单，连续 60 次播放刷新后 isHeld 保持 true，按钮和根菜单身份不变。
- 检查显示模式→屏幕位置三级结构、画质子菜单、操作方式切换和下次快照勾选、开发者选项显隐、禁用状态、键盘/退出/导出回调。
- 测试不包含手指逐级点选子菜单；没有请求截图权限。
- 更新安装到已连接 iPad，并恢复正常启动，不携带自动投屏测试参数。

日志目录：work/repair/stable-menu/
