# 鹰锤互联 Mac：邮箱与 Apple 登录接入文档

交付日期：2026-09-09。适用客户端：YingchuiMac，最低 macOS 15；服务端：统一 WXESP_Backend；邮箱契约：`auth-v1.0.0`。

## 1. 办结范围

| 项目 | 交付状态 |
| --- | --- |
| 邮箱验证码登录 | 已接入统一后端、上线并完成真实用户验收 |
| 业务会话 | Keychain 保存、恢复、刷新轮换、退出、撤销验证均通过 |
| Apple 原生客户端 | 授权协调器和预备 HTTP 适配已写，默认关闭 |
| Apple 服务端 | 独立验证库、离线测试与配置样例已写；尚未接入统一 auth 路由、数据库及业务会话 |
| Apple 实际启用 | 用户暂缓开发者开通、签名配置和线上授权验收，留待后续工作 |

本项目按用户要求办结，关联定时检查已暂停。办结不代表 Apple 已上线。后续启用 Apple 仍须完成第 6 节的服务端接线，不能只修改 ID 或开关就投入使用。

## 2. 代码与部署位置

2026-09-09 后续更新：账号 Swift 代码已移至 `Shared/YingchuiAccount/`，由 Mac 与 iPad 共用。两端各自保留配置 JSON；iPad 接入和响应优化验证见 `ACCOUNT_PAD_REVIEW.md`。Apple 暂缓启用的决定不变。

Mac 项目根目录：`/Users/chongyang/iPhone_Project/Yingchui/yingchuihulian`。

| 位置（相对 Mac 项目根目录） | 职责 |
| --- | --- |
| `Shared/YingchuiAccount/AccountConfiguration.swift`、`Mac/YingchuiMac/Account/AccountConfiguration.json` | 公开配置加载与地址、版本校验 |
| `Shared/YingchuiAccount/AccountModels.swift` | 用户、业务会话、持久化记录和错误模型 |
| `Shared/YingchuiAccount/AccountHTTPService.swift` | v1 请求、响应和错误契约适配 |
| `Shared/YingchuiAccount/AccountHTTPTransport.swift` | TLS、代理配置、超时、缓存与重定向策略 |
| `Shared/YingchuiAccount/AccountKeychainStore.swift` | 系统登录钥匙串存储 |
| `Shared/YingchuiAccount/AccountSessionController.swift` | 恢复、单次刷新、撤销、请求世代隔离 |
| `Shared/YingchuiAccount/AccountModel.swift`、`AccountView.swift` | 邮箱输入、验证码倒计时、登录与退出界面 |
| `Shared/YingchuiAccount/AppleAccountAuthorization.swift` | 原生 Apple 授权、签名能力与授权状态检查 |
| `Mac/YingchuiMacTests/Account/` | 常规契约和会话测试 |
| `work/repair/mac-account/backend-unified-handoff-20260909/` | 已校验的统一认证源码、接线参考、契约及部署证据快照 |

后端 Apple 预备验证库：`/Users/chongyang/iPhone_Project/WXESP_Backend/services/user/appleauth/`。主要文件为 `config.go`、`client.go`、`verify.go`、`client_test.go`、`apple-auth.sample.json` 和 `README.md`。

线上只有统一 WXESP_Backend：入口 `main.go`，服务 `osmanthus_backend.service`，内部监听 8080。邮箱与原业务共用同一后端、数据库、身份和会话体系。原独立邮箱服务和 18090 代理已撤除。Mac 只调用下述 v1 接口。

交接目录是源码快照，不是另一套可部署后端；不要从本机旧主服务源码直接发布覆盖已经完成的统一认证实现。

## 3. Mac 配置

配置文件：`Mac/YingchuiMac/Account/AccountConfiguration.json`。

```json
{
  "baseURL": "https://chongyang.asia",
  "clientID": "com.yingchui.interconnect.mac",
  "contractVersion": "auth-v1.0.0",
  "appleEnabled": false,
  "useSystemProxy": false
}
```

| 字段 | 当前行为 |
| --- | --- |
| `baseURL` | 仅允许当前业务 HTTPS 域名；代码拒绝其他主机、HTTP、用户信息、端口、查询参数和额外路径 |
| `clientID` | 本机配置校验值，与 Mac Bundle ID 一致；不是登录凭据 |
| `contractVersion` | 必须与服务端 status 的版本一致 |
| `appleEnabled` | 当前为 false；将来还须服务端 `apple_available=true`、有效签名及完整接线 |
| `useSystemProxy` | false 表示账号请求直连；true 表示使用系统代理。修改后重新构建，不自动切换线路 |

配置打包在应用内，不使用环境变量。代理设置只作用于账号请求，不更改系统代理；TLS 证书仍由系统验证。请求不使用 Cookie 或缓存，不跟随重定向，请求/总资源超时分别为 20/25 秒。

账号入口位于主窗口右上角。未登录不影响现有局域网配对和投屏；业务登录凭据与配对/TLS 凭据分别管理。

## 4. 邮箱接口与接入顺序

公共前缀：`https://chongyang.asia/api/auth/v1`。请求和响应使用 UTF-8 JSON；服务端响应 `Cache-Control: no-store`。除下表指定的 POST JSON 外，访问凭据只放在 Authorization 请求头。

| 方法与路径 | 请求 | 成功响应 |
| --- | --- | --- |
| `GET /status` | 无 | 200，版本和登录可用性 |
| `POST /email/code` | `{"email":"name@example.com","purpose":"login"}` | 200，`{"expires_in":300,"retry_after":60}` |
| `POST /email/login` | `{"email":"name@example.com","code":"123456"}` | 200，Session |
| `GET /me` | `Authorization: Bearer <access_token>` | 200，User |
| `POST /refresh` | `{"refresh_token":"<refresh_token>"}` | 200，轮换后的 Session |
| `POST /logout` | `{"refresh_token":"<refresh_token>"}` | 204，无正文 |

表中邮箱、验证码及尖括号字符串仅用于说明字段，不是可用凭据。后端另提供 `PATCH /me` 修改昵称和头像；当前 Mac 登录界面未实现资料编辑、主动合并身份或账号删除。

### 4.1 状态检查

2026-09-09 验收时实际返回：

```json
{
  "version": "auth-v1.0.0",
  "backend": "wxesp_backend",
  "auth_mode": "unified",
  "email_available": true,
  "apple_available": false
}
```

先检查版本和可用性，再开放发送验证码。后续部署的实时状态以接口为准；404、服务不可用、版本不符必须报错。

### 4.2 登录

1. 邮箱去除首尾空白并转小写；只接受 ASCII 单一邮箱地址，最大 254 字节，不接受显示名称或控制字符。
2. 调用 `/email/code`，`purpose` 固定为 `login`。按响应期限显示重发倒计时。
3. 用户自行收取并输入六位验证码，调用 `/email/login`。首次验证成功由后端创建账号。
4. 检查响应结构、用户身份、令牌与期限；再用 access 调 `/me`，确认用户 ID 一致。
5. 将真实 Session 写入独立 Keychain，界面显示服务端确认的昵称或邮箱。

验证码有效期 5 分钟，每邮箱和用途最多 5 次错误尝试，成功后原子消费。同邮箱重发间隔至少 60 秒，每邮箱每小时最多 5 次、每来源 IP 每小时最多 20 次；以服务端限流响应为准。新旧入口共用验证码和身份，Mac 不调用旧登录地址。

### 4.3 User 与 Session

下列为结构示意，令牌占位符不可用于运行：

```json
{
  "token_type": "Bearer",
  "access_token": "<opaque-access-token>",
  "expires_in": 900,
  "refresh_token": "<opaque-refresh-token>",
  "refresh_expires_in": 2592000,
  "session_id": "<server-session-id>",
  "is_new_user": false,
  "user": {
    "user_id": "<stable-server-user-id>",
    "nickname": "",
    "avatar_url": "",
    "email": "name@example.com",
    "identities": ["email"],
    "legacy_profile_ids": []
  }
}
```

`GET /me` 直接返回上述 `user` 对象。空昵称和空历史映射是合法响应。`user_id`、邮箱、旧 profile ID 都不是鉴权凭据；不能填入 access 或 refresh 字段。

access 最长 15 分钟。refresh 从最初登录起最长 30 天，轮换不延长期限，响应返回剩余秒数；access 到期时间不能晚于 refresh。每次登录建立独立 session，退出只撤销所属 session。

### 4.4 恢复、刷新与退出

- Keychain service：`com.yingchui.interconnect.mac.account`；account：`business-session.v1`。使用 macOS 系统登录钥匙串及签名访问控制，不写普通配置文件。
- 启动或回到前台时恢复会话，并用 `/me` 确认真实身份。访问令牌临近到期时刷新；并发调用共用同一个刷新任务。
- 刷新提交前先保存待撤销标记；成功后才保存新的 access/refresh。同一旧 refresh 只能消费一次，重放会返回 `refresh_reused` 并撤销整个 session。
- 刷新超时、取消或响应不确定时，不重放旧 refresh。保留受保护的撤销记录，仅允许重试 logout，之后重新验证码登录。
- 退出先持久化撤销意图，成功收到 204 后删除 Keychain。退出网络失败明确报错，可重试幂等 logout。
- 退出、切换及取消通过任务取消和请求世代编号阻止迟到响应恢复账号。邮箱登录提交结果不确定时，重新发码验证，不假定原验证码仍可用。

### 4.5 错误处理

统一错误形状：

```json
{
  "error": {
    "code": "rate_limited",
    "message": "请求过于频繁",
    "retry_after": 60
  }
}
```

`retry_after` 只在限流时出现，并与 HTTP `Retry-After` 整数秒一致。

| 状态/错误 | 接入处理 |
| --- | --- |
| 400 `invalid_request` | 修正输入或请求结构 |
| 401 `invalid_code` | 验证码无效或过期，提示重新验证 |
| 401 `invalid_access_token` | 不展示为已登录，按会话规则处理 |
| 401 `invalid_refresh_token` / `refresh_reused` | 会话失效，不能重放 refresh |
| 409 `identity_conflict` | 明确报告身份冲突，不按邮箱自动合并 |
| 429 `rate_limited` | 按服务端重试时间禁用重复发送 |
| 503 或网络/TLS 错误 | 显示服务或连接错误，禁止假成功及线路回退 |

令牌、验证码、私钥、数据库/SMTP 密码不得写入日志、URL、聊天或中转附件。

## 5. 统一后端接入说明

现有接线链为 `main.go → bootstrap.ConfigureServices → user.Configure/EnsureAuthSchema → routes.RegisterAll`。认证模块位于 `services/user/auth/`，SMTP 模块位于 `services/user/mailtransport/`；参考代码位于交接快照的 `reference/*.go.txt`。

认证配置由文件 `config/auth.json` 提供，公开样例仅说明形状：

```json
{
  "code_key": "",
  "trusted_proxies": ["127.0.0.1/32", "::1/128"]
}
```

该空样例不能直接上线。真实摘要密钥、SMTP 和数据库配置由统一后端安全管理，文档不包含其值。已有部署必须保留认证表、稳定身份、会话和验证码摘要密钥，不重新生成一套用户库。

只有明确受信任的反向代理可提供真实来源 IP。新旧邮箱入口调用相同的验证码消费、身份映射及会话函数；旧响应里的 `token` 可能是历史业务 ID 别名，Mac 必须使用 v1 返回的真实 Session。

## 6. Apple 登录后续接入

### 6.1 当前已准备的代码

Mac 使用 AuthenticationServices 原生授权，包含实际签名能力检查、随机 state、服务端 nonce 原样传入、取消与超时处理、授权结果完整性检查，以及 Apple 用户授权状态检查。

后端 `appleauth` 库按当前实现执行 RS256/JWKS 身份令牌校验，验证 issuer、audience、sub、iat、exp、nonce 和适用时的 c_hash；随后兑换授权码，再次验证兑换结果的 sub 与 nonce 一致。client_secret 使用服务端 P-256 私钥进行 ES256 签名，当前实现期限为 5 分钟。授权码兑换不自动重试。

Apple 上游 access/refresh/identity token 只留在服务端；库中相关结构已禁止直接 JSON 序列化到客户端。Mac 最终应收到统一业务 Session。

### 6.2 预备 HTTP 契约（尚未部署）

以下是 Mac 当前关闭状态的适配预期，须与未来统一后端定稿确认，不代表线上已有这些接口：

| 方法与路径 | 请求 | Mac 当前预期响应 |
| --- | --- | --- |
| `POST /api/auth/v1/apple/challenge` | `{}` | `challenge_id`、`nonce`、`expires_in`，最长 300 秒 |
| `POST /api/auth/v1/apple/login` | `challenge_id`、`identity_token`、`authorization_code`、可选 `nickname` | 与邮箱一致的 Session，identities 包含 apple |

预期流程：后端创建一次性 challenge → Mac 将 nonce 交给系统授权并校验返回 state → Mac 提交授权结果 → 后端原子消费 challenge 并完成 Apple 验证 → 签发统一业务 Session → Mac 校验 `/me` 后保存 Keychain。

### 6.3 仍需完成的服务端工作

1. 在统一 auth 中实现 challenge 的强随机 nonce、数据库持久化、期限、限流和原子一次性消费；失败直接报错，不改用内存替代。
2. 原子消费 challenge 后调用 `appleauth.Client.Authenticate`；不相信客户端提交的 sub、user_id 或 audience。
3. 以固定 Apple issuer 和已验证 Subject 建立唯一身份，接入同一 `auth_users`、`auth_identities` 和业务 session。当前 `newSession/issueSession` 为包内函数；`LegacySession` 不是 Apple 签发入口。
4. 支持隐藏邮箱及没有邮箱的 Apple 用户。姓名仅作为首次提供的可选资料；不能凭相同邮箱自动合并其他身份。
5. 加密保存 Apple 上游 refresh，并完成授权撤销检测、通知校验与去重或周期检查。加密密钥独立管理，不复用验证码摘要密钥。
6. 注册正式路由、错误契约及实际可用性检查。数据库或配置未就绪时，`apple_available` 必须为 false。
7. 补充数据库并发、挑战重放、身份冲突及业务会话测试；完成实际签名和本人授权验收后再开启。

普通业务 logout 只撤销当前业务 session。`appleauth.Client.Revoke` 用于断开 Apple 关联或账号删除时的上游撤销，不能在普通退出时直接调用以免影响其他设备关联。绑定、删除流程尚需独立验证与事务设计。

### 6.4 用户后续需提供的配置

当前已知公开值：Team ID 为 `Q269MU4N6F`；Mac App/Client ID 为 `com.yingchui.interconnect.mac`。Key ID、Primary App ID/分组及真实私钥尚待用户开通后确认。

1. 开通或恢复有效 Apple Developer 资格，在正确团队下为 Mac App ID 启用 Sign in with Apple。
2. 确认 Primary App ID 和分组；创建关联的 Sign in with Apple Key，记录公开 Key ID，妥善保存下载的 `.p8`。
3. 通过安全部署流程将 `.p8` 放到服务端，提供绝对路径，文件权限限制为运行用户读取，例如 `0600`。不把私钥内容传给 Mac 或写进中转区。
4. 在 Xcode 的 Signing & Capabilities 添加 Sign in with Apple，取得匹配的 provisioning profile，并核对实际构建产物签名。

服务端预备配置文件 `config/apple-auth.json`：

```json
{
  "enabled": false,
  "team_id": "Q269MU4N6F",
  "client_id": "com.yingchui.interconnect.mac",
  "key_id": "",
  "private_key_path": ""
}
```

当前库要求 `.p8` 为 P-256 PKCS#8 私钥；空 ID、错误类型、无效路径或过宽权限报错。配置读取函数已有，统一后端启动接线仍待完成。

完成服务端接线、私钥和签名配置之后，才分别设置服务端 `enabled=true`、Mac `appleEnabled=true`，并核验线上 `apple_available=true`。仅修改 JSON 不会赋予 `com.apple.developer.applesignin` 签名能力。

当前方案为原生登录。若将来增加网页授权，须另外登记 Services ID、域名和回调，并开发对应流程；不填写猜测的 Return URL。

## 7. 构建、验证与交付证据

Mac 项目根目录执行：

```sh
xcodebuild -workspace YingchuiInterconnect.xcworkspace -scheme YingchuiMac -destination 'platform=macOS' build
xcodebuild -workspace YingchuiInterconnect.xcworkspace -scheme YingchuiMac -destination 'platform=macOS' -derivedDataPath work/repair/mac-build test
```

将来启用 Apple 后检查实际签名：

```sh
codesign -d --entitlements :- work/repair/mac-build/Build/Products/Debug/YingchuiMac.app
```

签名应含 `com.apple.developer.applesignin` 的 `Default` 能力并匹配有效 profile。Apple 私钥和 client_secret 不得进入 Mac 包。

已有 Go 环境时，在对应模块根目录执行；测试不使用生产数据库：

```sh
# 在 WXESP_Backend 根目录验证 Apple 预备库
go test -race ./services/user/appleauth -count=1

# 在统一认证交接快照根目录验证认证包
go test -race ./services/user/auth ./services/user/mailtransport
```

数据库集成测试带 `integration` 标签，须显式提供本机隔离数据库配置 `-auth-db-config`。该类测试未在本 Mac 环境另跑，不能将单元测试结果当成完整数据库或主服务验收。

| 已完成验证 | 证据（相对 Mac 项目根目录） |
| --- | --- |
| 30 项常规 Mac 测试及直连状态验证 | `work/repair/mac-account/direct-route-tests.log` |
| 最新 Mac 构建 | `work/repair/mac-account/build-direct-route.log` |
| 统一后端真实登录后的恢复、刷新、退出与旧 access 返回 401 | `work/repair/mac-account/live-unified-session-tests.log` |
| 脱敏结果，verification_complete=true | `work/repair/mac-account/live-session-result.json` |
| Apple 预备库 7 个顶层测试及子用例、race 检查 | `work/repair/mac-account/apple-tests.log` |
| 统一认证包 race 单元测试 | `work/repair/mac-account/backend-unified-tests.log` |
| 线上统一服务状态 | `work/repair/mac-account/status-unified-body.json` |

2026-09-09 16:54 的真实邮箱验证覆盖：用户收码登录、Keychain 恢复、`/me` 身份确认、access/refresh 轮换且用户和 session 不变、轮换结果持久化、再次恢复、logout、Keychain 清除、旧 access 返回 401、重复 logout 成功。验收结束已退出账号，正常使用时重新登录即可。

生产验证脚本保存在 `work/repair/mac-account/AccountLiveVerificationTests.swift`，已移出常规测试目录；它会操作真实用户会话并退出账号，不应放进日常测试或无人值守测试。此前代理连接失败的日志保留为历史证据，最终通过结果以上述统一服务日志为准。

统一源码交接包 SHA-256：`33b4525ae0abbe63bcbe7e0c178fd80319d90808ccbe94e3acb5a99d8c250775`，包内 32 文件哈希已核验。邮箱阶段回执：`msg_1788944101594_040a9ca5308aef7fd294b84b`，发布后已独立回读正文一致。

Apple 尚未完成的实机验证包括：本人成功授权与取消、隐藏邮箱、正式签名安装、重启恢复、授权撤销，以及服务端挑战和身份的完整集成。后续继续此部分时，以最新统一 backend 源码和本节范围为起点。

## 8. 补充资料

- [Apple 专项后续配置与接线说明](MAC_APPLE_LOGIN_SETUP.md)
- [账号联合开发及验收记录](MAC_ACCOUNT_COLLABORATION.md)
- [统一邮箱正式契约快照](work/repair/mac-account/backend-unified-handoff-20260909/docs/auth-v1.md)
- [统一后端源码交接说明](work/repair/mac-account/backend-unified-handoff-20260909/docs/email-source-handoff.md)

文档中的公开配置与状态以本次交付版本为准；真实密码、密钥、验证码及用户令牌均未写入。
