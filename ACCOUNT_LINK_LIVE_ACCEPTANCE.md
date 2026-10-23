# 账号联动与 VIP 线上验收

2026-09-10：后端开关已启用，真实 Mac/iPad 联调通过。原有 iPad 登录保留，Mac 通过联动获得登录；临时测试会话已退出并清理。

## 线上状态

- 公网 status：`device_link_available=true`、`email_available=true`、`apple_available=false`。
- 生产配置：`device_link_enabled=true`。
- 数据库：用户数 1、VIP 用户数 1、累计发放 1；本轮联动和测试未增加用户或占用 VIP 名额。

## 真实设备验证

1. 初始状态：iPad 已有真实账号且 `/me` 返回 VIP；Mac 没有账号会话。
2. iPad 正常应用通过已有证书和可信配对连接 Mac。Mac 自动请求授权并登录成功，保存自己的钥匙串会话。未输入验证码、未通过普通文件交换凭据。Mac 窗口的无障碍信息确认存在 VIP 标识。
3. Mac → iPad 使用同一真实 iPad、真实网络发现/证书/配对和线上接口，以隔离钥匙串作为新接收端，避免覆盖用户原有登录。联动成功，用户一致、VIP 为 true，Session 与原 iPad 会话不同。
4. 新接收会话刷新后编号稳定、凭据轮换；原 iPad 会话仍通过 `/me`。随后退出临时会话，钥匙串清空、用户/VIP 状态清除、自动再登录被阻止，旧 access 被服务器拒绝，原登录继续有效。
5. Mac 联动会话独立刷新、持久化、重新加载并确认 VIP 全部通过；随后再次在 iPad 真机确认原登录和 VIP 仍有效。

不同账号不覆盖、重复消息、断线/取消/手动登录竞态由既有自动化单元测试覆盖；本轮没有为这些情况在生产新建其他用户，也没有在生产测试 10,000 人边界。后端提供的隔离数据库专项验证与实机验收分别记录。

## 证据与清理

日志位于 `work/repair/link-vip-live/`：`pad-to-mac.log`、`pad-physical-link.log`、`mac-final-session-test.log`、`pad-final-session-test.log`、`migration-probe.json`。日志不包含验证码、access/refresh、grant 或 verifier。

第一次反向测试因测试构造器默认禁止启动网络而超时；将本次实机测试明确设为 `startServices: true` 后通过，未改动正式应用行为。临时实机测试源码已移出日常测试目录，保存在上述证据目录，避免以后测试意外操作真实会话。
