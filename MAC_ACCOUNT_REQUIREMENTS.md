# 鹰锤互联 Mac 账号登录对接需求

> 2026-09-10 用户新增约定：所有账户功能默认 Mac 与 iPad 同步更新。当前 Apple 绑定增量状态见 [双端 Apple 账户绑定](ACCOUNT_APPLE_BINDING.md)。


> 项目已按用户要求办结（2026-09-09），关联定时检查已暂停。最终交付入口：[邮箱与 Apple 登录接入文档](MAC_EMAIL_APPLE_LOGIN_INTEGRATION.md)。邮箱已验收；Apple 启用及生产集成为明确暂缓的后续工作。

> 最新状态（2026-09-09 16:54）：统一 WXESP_Backend 与 Mac 邮箱阶段已通过真实登录、恢复、刷新轮换、持久化、退出、旧令牌 401 及幂等退出验证；Mac 30 项常规测试通过。应用已重新打开并处于退出状态。Apple 只保留预备代码和配置文档，暂缓启用/部署，不声明双登录全部完成。下文早期状态属于历史记录。持续状态见 `MAC_ACCOUNT_COLLABORATION.md`，Apple 后续步骤见 `MAC_APPLE_LOGIN_SETUP.md`。

日期：2026-09-09。客户端：YingchuiMac，SwiftUI，最低 macOS 15，Bundle ID `com.yingchui.interconnect.mac`。

## 已确认

- 用户要求增加 Apple 和邮箱两种登录方式；界面启动项文字改为“开机时启动”，底层仍使用系统登录项。
- 已阅读用户提供的 Deploy_Tool、中转区说明及服务清单实现说明。Deploy_Tool 是部署控制台，业务用户服务属于 `DevicePlatform/WXESP_Backend`。
- 已通过服务器本机 `GET /api/system/services` 确认线上 `user` 模块登记了邮箱验证码发送、邮箱登录、资料管理及账号删除。服务登记不等于接口联调通过。
- 最初的 Deploy_Tool 目录没有业务处理器；用户随后提供 `WXESP_Backend`，现已找到 `services/user/email.go` 和 `service.go`。源码接口为 `POST /email/code`（email、可选 type，成功返回 errcode=0、errmsg=ok）及 `POST /email/login`（email、code，成功返回 token）。公开 HTTPS 映射及线上版本仍需确认。
- 旧登录响应中的 token 实际就是邮箱地址，不是安全会话令牌；验证码仅保存在进程内 map，无期限、尝试次数或用途隔离，使用 math/rand 且日志输出验证码。校验与删除分两次加锁，存在并发重复使用窗口。`profile.go` 的资料读写直接使用客户端传入 id，处理器未校验会话。需后端修正后接入，不能把旧返回值当作有效账号凭据。
- 线上服务清单没有列出 Apple 登录，需后端确认现状。
- 中转区网页现有项目仅 DeviceStudio 和 HomeNAS；本次需求发送到 DeviceStudio 的后端频道，正文注明鹰锤互联，避免发到不相关的 HomeNAS 协作流。

## 客户端需求

1. Mac 主窗口提供简洁账号入口，登录页支持系统 Apple 登录按钮、邮箱、验证码、发送验证码和登录。展示真实加载、失败及限流状态，不能假登录。
2. 邮箱登录复用已有用户体系和验证码服务，不复制一套账号库。验证码长度、有效期、重新发送间隔由正式契约确定。
3. 登录后显示服务端确认的用户身份，支持退出和重启后恢复会话。令牌存入 Keychain，不能写入普通配置、日志或中转区。
4. 网络、解析、过期、撤销、账号禁用均显式处理。退出或账号切换必须取消旧请求，迟到响应不能恢复旧账号。
5. 账号认证与当前 iPad 的局域网配对、可信设备凭据分别管理。暂不因未登录而禁用现有投屏；同账号自动配对、云端设备同步等权限变化另行确认。
6. 以配置文件提供公开 API 地址；缺失配置直接提示无法对接，不默认使用内网、localhost、Windows 盘符或未经确认的接口。保留正常 TLS 证书验证。
7. 模块拆分为账号模型、接口客户端、Keychain 会话存储、Apple 授权和界面，复用现有公共按钮与动效。

## 请后端提供或实现

- 提供现有邮箱验证码发送、验证码登录接口的完整方法、路径、请求/响应 JSON、成功/失败状态码及公开 HTTPS 联调地址，附接口源码位置或 OpenAPI。不要在中转区发送真实验证码、账号令牌或密码。
- 明确邮箱校验/规范化、验证码用途和长度、有效期、重发间隔、失败次数、邮箱与 IP 限流、429 的重试字段，以及登录是否自动创建账号。
- 明确当前用户、会话恢复、刷新、退出/撤销、账号删除接口，以及 access/refresh token 字段与期限。若当前依赖 Cookie/CSRF、微信 openid 或 Windows 客户端标识，请提供原生 Mac 的正式接入方案，不接受把 email/user_id 当作认证凭据。
- 确认已有用户是否跨产品共用、Mac 客户端如何标识和授权、Apple 与邮箱账号如何绑定。不得仅凭相同邮箱自动合并账号。
- Apple 登录优先评估 AuthenticationServices 原生授权：后端验证 Apple 身份令牌签名、issuer、audience、有效期及 nonce，处理授权码的一次性使用，签发自己的业务会话。提供 challenge/nonce 与兑换接口契约、撤销处理和错误码。
- 确认允许的 Mac App ID/audience、与其他 Apple 客户端的分组关系、开发与发布签名能力。若正式分发必须使用网页授权，须另给已登记的 Services ID、HTTPS 授权入口、回调及 state/PKCE 方案，不能临时猜测 callback。
- Apple 私钥和 client_secret 仅存服务端；需提供给 Mac 的配置只包含公开标识。兼容隐藏邮箱及姓名仅首次授权返回的情况，以验证后的 issuer/sub 标识 Apple 身份。
- 回复各项“已实现 / 待实现 / 需用户在开发者后台配置”的状态、部署版本、精确 JSON 样例和验收结果。

## 验收

- 已存在邮箱和新邮箱按既定规则登录；错误/过期验证码、频繁发送、断网和服务错误均真实报错。
- Apple 成功、取消、重放、错误 audience/nonce、过期令牌、隐藏邮箱及撤销授权得到正确结果。
- 两种登录返回一致的业务用户与会话结构；重启恢复、刷新、并发刷新、退出撤销和账号切换经过验证。
- Mac 编译、接口契约测试、Keychain 生命周期和界面检查通过。真实 Apple 授权、接收邮件验证码需使用者参与，不伪造验收。

## 当前交付边界

本轮已完成启动项文字修改和后端需求交接，并确认用户补充的 WXESP_Backend 是所需业务源码。账号登录尚未接通；安全会话契约与 Apple 配置明确后继续实现，不将需求文档标记为登录功能完成。

交接回执：DeviceStudio → 后端，类型“交接”，来源 B 地。消息编号 `msg_1788935351395_1a95121c7da832c43bdacf9e`，幂等请求编号 `yingchui-mac-account-20260909-01`。服务端返回 HTTP 201，已回读核对正文一致。精确发送内容与回执保存在 `work/repair/mac-account/relay-request.json` 和 `relay-published.json`；不包含访问凭据。

参考：
- Apple 原生授权：https://developer.apple.com/documentation/signinwithapple/authenticating-users-with-sign-in-with-apple
- Apple 服务端验证：https://developer.apple.com/documentation/signinwithapple/verifying-a-user

补充源码审查回执：`msg_1788935577569_935db3c30786043c055e4302`，回复原交接。首次发布 HTTP 201，幂等复查 HTTP 200；后续独立读取已确认正文一致。

## 后端回复与 Mac 配置确认（2026-09-09）

后端回复 `msg_1788935980362_ae345d4d1de0ce792f4baae3`：确认业务 HTTPS 基址为 `https://chongyang.asia`；当前尚未实现真正的会话、刷新/撤销及 Apple 登录。本轮后端只检视，未部署新认证实现。旧客户端将 token 当作资料 id，迁移需保留稳定身份与关联数据。

Mac 当前实际签名团队 `Q269MU4N6F`，Bundle ID `com.yingchui.interconnect.mac`；签名中没有 `com.apple.developer.applesignin`，未附 Apple 登录描述文件，能力尚未就绪。优先原生授权，应用分组及正式分发能力未确认。已请求后端先落实邮箱安全会话契约，再明确 Apple 配置与迁移安排；Mac 登录模块尚未实现。

回复回执：`msg_1788936194770_4ff3daacd718a9ba2d759bfc`，请求 `yingchui-mac-account-config-20260909-03`，发送 HTTP 201 并回读一致；对方消息已标记 B 地已读。完整正文见 `work/repair/mac-account/relay-config-reply.json`。
