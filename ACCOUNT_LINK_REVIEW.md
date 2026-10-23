# 双端账号联动进度

2026-09-10 最新状态：线上后端已启用，双向真实设备联动、独立会话刷新与退出、VIP 已完成验收，见 `ACCOUNT_LINK_LIVE_ACCEPTANCE.md`。以下为上线前的实现与交接记录。

## 行为

- Mac 与 iPad 完成证书验证及可信配对后，已登录端可让未登录端自动登录同一账号，两个方向一致。
- 已有账号不会被覆盖，不同账号也不会自动合并。
- 接收端通过后端获取独立会话，各自保存钥匙串，不传输或共用 access/refresh token。
- 默认仅退出当前设备；退出意图会持久阻止自动登录，手动登录成功后解除阻止。
- 断开连接、撤销配对、主动取消或手动登录会使迟到的联动响应失效。
- 旧客户端通过 hello 可选能力字段兼容；没有声明能力的设备不会收到新消息类型。
- 联动错误记录在账号消息和脱敏日志中，不触发视频重连。

## 实现

- `Shared/YingchuiAccount/Linking`：一次性授权协调、PKCE、生命周期、HTTP 接口和账号模型适配。
- `Shared/YingchuiProtocol/.../AccountLinkMessage.swift`：有边界校验的协商消息，不包含长期令牌。
- `Mac/.../Host/MacAccountLink.swift`、`iPad/.../Connection/PadAccountLink.swift`：仅在可信通道中启用；网络队列撤销授权立即使 lease 失效。
- `AccountSessionController.accept`：确认身份后再次检查会话占用及授权；异步保存前后均检查，防止并发登录覆盖或取消后恢复。

## 后端待完成

现网 `GET https://chongyang.asia/api/auth/v1/status` 返回 auth-v1.0.0，邮箱可用、Apple 关闭，没有 `device_link_available`。客户端会明确将联动能力判为不可用，保留现有登录和投屏。

新增契约已发送到 devicestudio 中转区，请求编号：

- `yingchui-account-link-contract-20260910-01`
- `yingchui-account-link-contract-20260910-02`

后端需要提供：

1. status 的 `device_link_available` 能力字段。
2. `POST /api/auth/v1/device-link/grants`：来源 Bearer，目标 client ID、S256 challenge；返回 60 秒一次性 grant。
3. `POST /api/auth/v1/device-link/exchange`：目标 `X-Client-ID`、grant、verifier；原子单次兑换独立会话，检查来源会话未撤销。

verifier = base64url(randomBytes(32)) 无填充；challenge = base64url(SHA256(UTF8(verifier))) 无填充。服务端只保存 grant 摘要，禁止记录任何凭据。错误响应遵循现有认证格式。

不能以旧 WXESP_Backend 目录覆盖后端方当前 Platform_Backend 源码。当前尚未收到新增接口实现或部署回执。

## 验证

- Mac 账号相关共 38 个不同测试通过；iPad 真机相关共 27 个不同测试通过。
- 共享协议 73 个 Swift Testing 测试、4 个 XCTest 测试通过。
- 已覆盖双向独立会话、不同账号保护、旧后端能力、重复消息、非法/撤销通道、迟到兑换、退出阻止自动登录、手动登录优先、并发提交保护和 HTTP 契约。
- 接口测试发现并修复了缺失 `X-Client-ID` 请求头的问题。
- Mac 与 iPad Debug 构建通过。测试证据位于 `work/repair/account-link/`。
- 尚不能声称真实账号联动成功；后端上线后还需分别验证 Mac→iPad、iPad→Mac，以及刷新和单端退出互不影响。
