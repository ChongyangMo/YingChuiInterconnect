# 显微镜无线显示方案（封存）

2026-09-09：用户要求封存，暂停研究、采购和开发。恢复主线 Mac → iPad 投屏；只有用户明确重启此方案时才继续。

## 已知条件

- 显微镜：苏州欧米特 OMT-1950HC，具有 HDMI 输出；用户确认 USB 为普通 USB 摄像头。
- 厂家标准配置标注 HDMI 1920×1080、60 fps，不能据此推定 USB 格式和帧率。实际相机头、USB 视频模式、HDMI/USB 测量叠加是否一致尚未验证。
- 当前 iPad Air 3 使用 Lightning。方案以网络接收为主，不假定能直接接普通 UVC 摄像头。

## 成本优先的候选方案

1. 已有安卓手机：显微镜 USB → OTG → 安卓 USB Camera 应用 → 局域网 RTSP/HTTP → iPad 播放器。已有数据线时，OTG 预算约 5～15 元。
2. 使用 HDMI：显微镜 HDMI → UVC 采集卡 → OTG → 安卓手机 → Wi-Fi → iPad。已有手机和路由器时，新增配件预算约 30～70 元；长期供电配件另预留 30～60 元，需先确认手机支持 OTG 同时充电。
3. 独立开发板：RV1106（Luckfox Pico Ultra W）＋TC358743 HDMI→CSI 桥接板。有开源参考，单件硬件暂按 250～350 元估算，不含开发人工、运费及打板返工；不是已经确认可下单的整套报价。

最低成本以已有安卓手机为前提。手机型号尚未知，不保证 OTG、充电、实际帧率、延迟与连续运行表现。先以 720p30 验证，再尝试 1080p30；均为测试目标而非实测结果。ESP32-S3 不适合作为需要自行编码的高清 HDMI 方案；ESP32-P4 仍需采集桥接与无线模块。RK3588、AX630C 成品或开发板因本次成本要求不优先。

## 若将来恢复

先确定闲置安卓手机型号和接口，再验证本机 USB 预览、局域网 iPad 播放和持续供电。现有鹰锤互联没有通用 RTSP 摄像头输入；融合到 App 需要另行开发，当前未实施。

参考资料：

- 厂家规格：https://www.hd-microscope.com/OMT1900xilieshipinxianweijing/255.html
- 安卓发送应用：https://play.google.com/store/apps/details?id=com.shenyaocn.android.usbcamera
- iPad 验证播放器：https://images.videolan.org/vlc/download-ios.html
- RV1106 HDMI 开源参考：https://oshwhub.com/madbob/luckfox_tc358743

