# 双端 Apple 账户绑定

2026-09-10。账户功能按用户要求默认同步更新 Mac 与 iPad；优先使用 Shared/YingchuiAccount 共享实现，并分别编译和验证两端。

## 当前交付

邮箱用户打开账户可点击“绑定 Apple 账户”；已包含 Apple 身份的用户显示“已绑定 Apple”。绑定使用当前独立会话与原生系统授权，提交后通过 /me 再次确认，保留用户编号、已验证邮箱及 VIP。另一端下次打开账户会刷新身份。邮箱会话不会因为绑定被改写为依赖系统 Apple 凭据的会话。

客户端使用独立的 apple_binding_available 能力，不提前开放原来的 Apple 登录。服务未开放时点击明确报错。授权取消、关闭账户、退出后的迟到响应不会发布旧账号；提交结果不确定时下次打开重新查询，不自动重放单次凭据。

实现：Shared/YingchuiAccount/AppleBinding 下的接口与流程模块，AccountSessionController 的资料确认，以及共享 AccountView / AppleAccountButton。Mac 与 iPad 的 Xcode 目标均包含这些共享文件。

## 后端待交付

中转区请求 yingchui-apple-account-binding-20260910-01，已返回 HTTP 201。具体约定保存在 work/repair/apple-binding/relay-request.json；截至本次检查尚无对方新回复，接口属于拟定契约，未声称线上可绑定。

- GET /api/auth/v1/status：apple_binding_available。
- POST /api/auth/v1/apple/bind/challenge：当前 Bearer、固定平台 X-Client-ID、空 JSON。挑战绑定同一用户/会话/平台及绑定用途，最长 300 秒。
- POST /api/auth/v1/apple/bind：challenge_id、identity_token、authorization_code，返回现有 User（含 identities、vip），不签发新业务会话。
- 必须校验真实 Apple 签名、issuer/audience/expiry/nonce、授权码兑换及 subject，单次消费；禁止按邮箱相同自动合并。另一账号已占用 Apple 身份时返回冲突。

## 验证与启用条件

Mac 和真实 iPad 各 27 项专项/回归测试通过（绑定 8、会话 10、展示 4、VIP 5）。包括请求路径/鉴权、独立能力开关、过期与畸形挑战拒绝、冲突报错、用户/邮箱/VIP 保持、会话不改写、另一端恢复身份、退出后迟到确认拒绝。测试使用隔离替身，不消耗线上用户/VIP 名额，不能视为真实 Apple 授权通过。

Mac 实际界面无障碍检查通过：绑定入口可点击、关闭态正确提示尚未开放、取消正常关闭账户窗。

双端构建成功；iPad 已安装并正常启动，Mac 已正常重开。构建、测试和安装日志位于 work/repair/apple-binding。

当前两端实际签名尚无 com.apple.developer.applesignin。需要开发者账号管理员为 Mac/iPad App ID 启用 Sign in with Apple 并正确分组、更新签名配置；后端配置真实 Apple 凭据和验证服务，完成部署。之后用户在首次系统 Apple 授权中确认。没有修改签名以伪装能力，也未将 Apple 私钥放入客户端。真实绑定、重复绑定、冲突和后续 Apple 登录同一用户的线上验收仍待这些条件满足。

Apple 配置说明：https://developer.apple.com/documentation/xcode/configuring-sign-in-with-apple
