# Mac 账号联合开发记录

> 项目办结（2026-09-09）：用户明确要求办结并输出接入文档。最终交付见 [邮箱与 Apple 登录接入文档](MAC_EMAIL_APPLE_LOGIN_INTEGRATION.md)。邮箱已完成统一后端真实验收，Apple 预备代码与后续事项已移交；关联检查 `mac` 已按最新办结指令暂停。下文“不暂停”等要求为办结前的历史记录，已被本次明确指令替代。

> 最新进展（2026-09-09 16:54）：统一 WXESP_Backend 与 Mac 邮箱阶段验收通过。用户真实再登录后，恢复、身份确认、refresh 单次轮换及持久化、重新恢复、logout、Keychain 清除、退出后旧 access 返回 401、重复 logout 均通过。此前代理 TLS 导致的验证缺口已补齐。应用已重新打开并处于退出状态。Apple 保留预备代码与 MD，按用户要求暂缓启用和生产集成；不声明两种登录全部完成。

## 当前约束与职责

- 本任务承接 Mac 账号模块及 DeviceStudio/后端的鹰锤互联交接链。自动检查已由父任务创建：ID `mac`，不要重复创建。
- 禁止 Git/worktree、环境变量、截图权限申请、假登录、静默错误和旧邮箱字符串 token。不得影响局域网配对/TLS/可信设备。
- 用户已授权中转区沟通、开发、编译、调试；2026-09-09 用户追加授权 Apple 服务端代码、交接及部署，随后明确：开发者资格未开通，Apple **只准备代码与配置 MD，暂缓启用和部署**。邮箱工作继续。
- 后端最新分工：对方只负责邮箱/旧客户端迁移，Apple 由本方准备。不要再催对方提供 Apple 实现或把 Apple 付费作为邮箱阻塞。

## 已处理交接

| 消息 ID | 处理 |
|---|---|
| msg_1788935980362_ae345d4d1de0ce792f4baae3 | 历史安全检视，前任务已回复/已读 |
| msg_1788936898365_d203bf43111177c13d10bad9 | auth-v1.0.0 契约，已下载验 SHA-256/已读 |
| msg_1788937730651_005a9f6752e80b0b219b9813 | 后端本机集成测试通过，尚未部署；已下载验哈希/回复/已读 |
| msg_1788937814755_b95398b7520c2bd839e3ec78 | 历史检视附件，已下载验哈希/已读 |
| msg_1788939051232_8c29082a2c27e2462f8288e0 | 邮箱/Apple 分工变化，已读并更新职责 |

本方回执：
- `msg_1788939305877_71beabed5fe3b7ffbbc39654`：契约采纳和实现进度，HTTP 201，已独立回读正文一致。
- `msg_1788939531833_d12d96680bc647674c03fb07`：Apple 归属及无敏感 auth 源码/接线请求，HTTP 201，已独立回读。
- `msg_1788939676736_8ae7f990be7f2a870d6ee7e8`：用户最新要求 Apple 只写代码与 MD、暂不启用部署，HTTP 201，已独立回读。

附件保存在 `work/repair/mac-account/attachments/`：
- auth-v1.md：`7114031108c37380a0a5ddc2d8fac1253681621102c7e89fa280394b802e3c16`
- auth-delivery.md：`091fac1e502eaeb555f6cce3efa381319aaf0587cc6974e5602e306319a364de`
- 登录服务检视与Mac对接.md：`6d49b8bf2f0f78ac18927d7b5fd8ac0a4628cc00e56ffbc57c3867f33251a0f9`

## Mac 已落实

`Mac/YingchuiMac/Account/` 模块：公开 JSON 配置、v1 HTTP 适配、系统登录钥匙串、会话控制、邮箱表单与系统 Apple 按钮、原生 Apple 授权协调器。入口位于主窗口右上角账号图标。

- 正式路径 `/api/auth/v1/status`、`email/code`、`email/login`、`me`、`refresh`、`logout`。
- 空昵称显示服务端确认邮箱；输入按 ASCII/trim/小写及六位数字契约处理。
- 独立 Keychain service，不修改 TLS/配对存储。固定使用 macOS 系统登录钥匙串及签名 ACL；不会在错误时改用普通文件。初次 Data Protection Keychain 实测缺 entitlement（-34018），现已改为明确的 Mac 登录钥匙串实现并真实读写验证。
- refresh 单次轮换：提交前持久化待撤销记录，防进程退出后重放；成功仅提交一次；超时、取消、异常结果不能再用旧 refresh。退出持久化撤销意图，失败可重试 logout；迟到响应不能恢复账号。
- HTTP TLS 使用系统验证，不跟随重定向、不用 Cookie/缓存、不输出令牌/响应正文。
- Apple 未启用，没有真实 Apple 登录成功验收。原生代码具备实际签名能力检测、nonce/state、取消及结果完整性检查。

## 验证证据

- 独立测试目录 `work/repair/mac-build`；2026-09-09 15:50 左右 30 项通过：11 契约、9 会话、4 显示选择、6 启动项。日志 `work/repair/mac-account/tests.log`。
- 默认 DerivedData 的 Debug 构建通过，正常运行版本已更新并有序重启。
- 使用现有辅助功能实际点击账号入口，无截图；登录表单真实显示“登录服务尚未部署。”，Apple/验证码/登录按钮禁用，完成/重新检查可用。
- 本机 HTTPS `GET https://chongyang.asia/api/auth/v1/status` 在 2026-09-09 15:32 返回 HTTP 404。响应证据 `status-headers.txt`、`status-body.json`。这不是邮件端到端联调通过。
- 没有向真实邮箱发码、没有创建生产测试用户、没有清除既有配对/钥匙串。

## 尚待完成

1. 邮箱阶段已验收，无需再次要求用户配合测试；只有新失败或接口变化才追加验证。
2. Apple 付费/后台/密钥/原生签名和生产集成暂缓，不重复询问用户开通。预备代码及 `MAC_APPLE_LOGIN_SETUP.md` 已交付，后续仍需统一 auth 接线，不能声称只填 ID 即可完成。
3. 未满足定时检查原要求的“两种登录实际完成”，因此仅发邮箱阶段回执，不作双登录最终验收、不暂停 `mac`、不自动归档。没有新可处理的回复时保持安静，不能反复运行测试或催用户。

## 统一邮箱阶段验收（16:54）

- 后端消息 `msg_1788943524594_a18cc354b0bb310017ec8053`：16:35:15 部署 `osmanthus_backend.service`，二进制 SHA256 `571dacdbcfc4e8f26758cb43e42649d4c7e23049244a3459b611605ce51e3adb`。后端回执确认独立进程、18090 端口及独立 Nginx 代理已移除；认证表、稳定身份、会话、HMAC 密钥保留。
- 本机直连 `/status` 实测 200、auth-v1.0.0、backend=wxesp_backend、auth_mode=unified、邮箱可用、Apple 关闭。证据 `status-unified-headers.txt`、`status-unified-body.json`。
- 新源码位于 `work/repair/mac-account/backend-unified-handoff-20260909`；整包 SHA256 `33b4525ae0abbe63bcbe7e0c178fd80319d90808ccbe94e3acb5a99d8c250775`，32 文件哈希全部通过。认证包 `go test -race ./...` 通过，SMTP 包无测试文件；带 integration 标签的数据库测试需要隔离数据库配置，未在本机运行。不能将模块包测试视为完整主服务构建测试。
- 用户再次在普通 Mac 应用真实登录，界面已确认账号。`live-unified-session-tests.log` 的 `testUnifiedSessionLifecycle` 于 16:54:01 通过；全过程使用线上接口及真实 Keychain，所有关键检查失败立即抛错。验证报告 `live-session-result.json` 的 `verification_complete=true`、`revoked_access_rejected=true`。
- 该次测试覆盖真实刷新、稳定用户/session、轮换存储、新控制器恢复、logout 清除本机状态、旧 access 的 `/me` 返回 401、幂等 logout。旧代理错误日志保留为历史，不能覆盖或冒充成功日志。
- 普通应用首次退出被打开的账号 sheet 拒绝（-128）；测试结束后已关闭 sheet 并有序退出，再重新打开普通应用并确认显示“登录”。临时生产测试已移出常规测试目录；没有持久化真实令牌用于补测。

## 真实邮箱验证与连接修复（16:28—16:44）

- 用户直接在 Mac 完成验证码登录，实际主窗口显示邮箱账号。真实 Keychain 恢复、服务端 `/me` 身份确认、refresh 单次轮换及存储、新控制器恢复通过，日志 `live-session-tests.log`。普通应用重启后也实际恢复账号。
- 首次退出发生 URLError -1005，未自动重放 refresh；新进程加载持久化待撤销记录后重试 logout 成功，Keychain 删除成功，重复 logout 成功。日志 `live-logout-first-attempt.log`、`live-logout-tests.log` 保留。
- 旧 access 的负向 `/me` 请求遇到 URLError -1200，日志指向系统代理 127.0.0.1:7890。这一项没有得到 401，不算通过。临时测试曾因非抛出断言继续写报告，已立即纠正报告为 `verification_complete=false`，并将验收脚本改为任一检查失败立即抛错。
- `AccountConfiguration.json` 新增 `useSystemProxy: false`，只控制账号业务请求。传输层明确关闭此会话的代理，保持系统 TLS 验证、无重定向、无失败后切换线路。需要系统代理时可将配置设为 true 并重新构建；未修改 macOS 系统代理。
- `direct-route-tests.log`：30 项常规测试与 1 项原生直连验证通过（后者连续请求线上 status 三次），共 31 项。`build-direct-route.log` 构建成功。
- 生产验收测试已移出常规测试目录，保存在 `work/repair/mac-account/AccountLiveVerificationTests.swift`；平时测试不会读写实际用户业务会话。结果文件 `live-session-result.json` 仅存状态布尔值和脱敏错误，不保存邮箱、用户 ID、验证码或令牌。
- 新范围消息 `msg_1788942618223_20da8603b974b2ab1a32ef79` 已采纳：统一 backend 保留已有身份、会话及 HMAC 密钥，Mac v1 地址不变。此前“旧主服务另行迁移、不阻塞最终验收”表述已被本条替代。

## Apple 预备代码交付（用户暂缓启用）

- 用户要求的配置说明已写 `MAC_APPLE_LOGIN_SETUP.md`，同份说明也保存在后端根目录。
- 后端独立 appleauth 包共 7 个顶层测试及子用例，`go test -race -v ./services/user/appleauth -count=1` 通过，日志 `work/repair/mac-account/apple-tests.log`。未改后端路由、邮箱实现或数据库，没有生产部署。
- Mac 默认 `appleEnabled: false`；challenge/login 预备请求、无邮箱 Apple 用户解析、系统授权状态检查已补齐。启用仍需完整后端接线/正式契约/签名与实际授权，不是仅修改 ID 就已完成。
- 离线代码附件 `work/repair/mac-account/appleauth-offline-20260909.zip`，SHA256 `dc4df9119fb7a787026d0b87b7e697d3dedb9f74b07fdbfcd7aee132c499a1bc`；每文件清单在 zip 内及 `appleauth-offline-manifest.json`。不含真实秘密。
- Go 工具链仅下载到本项目 `work/repair/mac-account/go-runtime/`，经官方元数据 SHA-256 校验，未设置环境变量或修改系统 PATH。

- 最新源码交付回执：`msg_1788940225226_5626b8bc082b50967013fa71`，HTTP 201；已独立 read 回读确认正文及附件 SHA256，附件 ID `att_c9f09b8e5d139240f56fb72adb2ad7e0`。

Email stage acceptance receipt: `msg_1788944101594_040a9ca5308aef7fd294b84b`; independently read back with exact content match. Request: `yingchui-mac-email-unified-accepted-20260909-10`.
