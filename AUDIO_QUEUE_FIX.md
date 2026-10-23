# iPad 声音队列修复

2026-09-08。

## 原因与修改

两端都把 UDP 分片数量当作声音容量：iPad 最多 16 个，Mac 最多 24 个，每片最长只有 5 毫秒。声音引擎冷启动或系统采集的一批数据就可能超过上限；容量归还还排在同一条积压队列后面。实机日志同时确认了 Mac 的“声音采集失败：声音队列已满”和首个普通视频帧直接解码失败。

- 按待渲染采样帧数计算容量，覆盖待调度任务和已提交缓冲，上限 500 毫秒；不是预先等待 500 毫秒再播放。
- 限制最多 512 个分片，避免极小分片制造无限任务。
- 渲染回调直接归还容量，不再排到网络数据后面，也不把输出设备延迟算作软件缓冲积压。
- 先提交首个声音缓冲，再启动播放节点。
- 停止、重连和失败都隔离旧任务与旧回调，失败后的排队数据不能重新启动声音引擎。
- 实际超过容量或设备初始化失败仍然明确报错并停止回传。
- 诊断摘要增加声音已渲染采样帧数与待渲染毫秒数。
- Mac 为整批声音预留最多 500 毫秒发送容量，网络完成回调在独立队列直接归还，不再受屏幕采集队列阻塞；网络失败回到采集队列明确停止。
- 起始关键帧缺失时明确报告、请求补发，在关键帧到达前不把依赖帧送入解码器；现有超时和重试上限仍生效，损坏帧仍报错。
- 视频解码完成时直接归还任务容量，用独立票据阻止旧回调影响重连后的计数；允许最多 16 个未完成解码任务，覆盖硬件冷启动短突发，超过上限仍明确失败。

回调时机依据：[Apple dataRendered](https://developer.apple.com/documentation/avfaudio/avaudioplayernodecompletioncallbacktype/datarendered)、[Apple dataPlayedBack](https://developer.apple.com/documentation/avfaudio/avaudioplayernodecompletioncallbacktype/dataplayedback)。

## 已完成验证

- 先在 iPad Air 3、iPadOS 17.7 真机复现：瞬间提交 40 个声音分片（200 毫秒），旧代码报“声音队列已满”。
- 修复后同一测试通过，最终真机完整 55 项测试通过，包括首个关键帧缺失、12 帧解码突发与重连隔离测试。
- 补充极小分片容量边界后，声音专项 7 项全部通过，覆盖冷启动突发、短分片、连续渲染、真实超限、即时归还容量、重连隔离和失败隔离。
- Mac 旧实现的 200 毫秒采集突发测试失败，修复后完整 40 个认证加密声音包、9,600 个采样帧抵达真实 UDP 接收端；Mac 全部 20 项测试通过。
- 两端 Debug、Release 编译与 Release 静态分析通过。

测试使用静音 PCM 验证真实 AVAudioEngine 渲染，不代表已验证声音听感和音画同步。

## 实机连续回传

Mac Release 与 iPad Air 3 实际连接通过，保留原配对与权限。初始 1920×1440 回传后成功切换到 2224×1668、60 fps；原生画质连续观察 24 个五秒间隔（两分钟），每个间隔的视频解码、声音渲染计数均增长，无队列满、解码失败、自动重试或断线。末次统计：视频累计解码 7,570 帧，当前音频流渲染 5,917,920 个采样帧，声音待渲染量保持 40–75 毫秒。声音计数在画质切换时重置，视频计数保留，因此两者累计区间不同。

期间在 Mac 播放过系统提示音；已验证声音数据持续进入 iPad 渲染引擎，听感和严格音画同步仍需实际听取判断，不把渲染计数当作扬声器听感证明。

调试过程中旧 Mac 曾卡在系统显示配置恢复调用；已结束对应调试进程，使用项目现有恢复逻辑按保存记录恢复，再运行修复版 Mac。未清空配对凭据，没有改动系统权限。

连续验证：`work/repair/audio-video-live-verified-2.log`、`audio-video-mac-final.log`、`audio-video-live-verification.txt`。

## 当前安装

Mac 正在运行 `work/repair/mac-release/Build/Products/Release/YingchuiMac.app`。iPad 正式版已覆盖安装并启动，安装保留现有配对；点“连接上次 Mac”即可再次回传。安装、启动结果分别保存在 `work/repair/audio-video-release-install.log` 和 `audio-video-release-launch.log`。

证据位于 `work/repair/`：`audio-queue-before-tests.log`、`audio-queue-final-tests.log`、`audio-video-final-tests.log`、`audio-sender-before-tests.log`、`audio-sender-final-tests.log`、`audio-queue-release.log`、`audio-sender-release.log`。
