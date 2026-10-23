# Apple 登录后续启用说明

本项目已于 2026-09-09 按用户要求办结，本文保留为后续 Apple 工作说明。Mac 项目内的完整交付入口是 `MAC_EMAIL_APPLE_LOGIN_INTEGRATION.md`；邮箱已验收，Apple 仍未启用。

更新：2026-09-09。用户暂未开通 Apple Developer Program，要求先保留代码与说明，暂不启用或部署 Apple 登录。

16:52 更新：邮箱和会话已统一集成到 WXESP_Backend，线上 status 已实测确认。最新认证源码和接线参考位于 Mac 项目 `work/repair/mac-account/backend-unified-handoff-20260909`，32 文件哈希已校验；下文较早的独立服务目录属于历史快照。未来 Apple 接线须以上述统一 backend 源码与契约为准。该迁移不代表 Apple 已启用。

## 现在的状态

Mac 邮箱按 `auth-v1.0.0` 实现；Apple 默认关闭，不影响邮箱、局域网配对或投屏。

已经准备：

- `Mac/YingchuiMac/Account/AppleAccountAuthorization.swift`：系统 AuthenticationServices 授权、实际签名能力检查、服务端 nonce 原样传入、随机 state 校验、取消、过期、授权数据完整性检查和系统授权状态检查。
- `AccountHTTPService.swift`：预备的 `/api/auth/v1/apple/challenge` 与 `/api/auth/v1/apple/login` 适配；默认不调用。
- `AccountConfiguration.json` 的 `appleEnabled: false`；同时受服务端 `/status` 的 `apple_available` 控制。两端明确开启后才出现可执行的 Apple 登录。
- 后端独立包 `/Users/chongyang/iPhone_Project/WXESP_Backend/services/user/appleauth/`：RS256/JWKS 验证、固定 issuer/audience/nonce/期限检查、ES256 client_secret、授权码兑换后二次验证、Apple 上游撤销、私钥文件权限检查及离线测试。

**尚未完成生产集成。** 16:15 已收到另一端独立邮箱服务源码，隔离保存在 Mac 项目的 `work/repair/mac-account/backend-handoff-20260909`，28 个文件逐一通过 SHA-256。`newSession`/`issueSession` 是 auth 包内函数；`LegacySession` 只允许旧邮箱/微信迁移，不是 Apple 签发入口。后续需将 challenge、稳定 Apple 身份、业务会话及上游令牌存储接到同一认证体系。当前新增包未注册路由，没有替换邮箱实现或部署服务。

新版邮箱契约已撤回此前 Apple 路由预留的交付承诺，独立邮箱服务不注册或代理 Apple 路由。Mac 中的 Apple 路径是关闭状态的预备适配，未来应与实际 Apple 后端契约一并确认，不能仅修改开关就启用。

因此，当前不能声称“以后只填 ID 即可”。完成下述集成后，启用才主要是填写配置与签名验证，不需要重写原生授权和密码学模块。

## 开通开发者资格后，用户需要做的事

1. 确认团队 `Q269MU4N6F` 的会员有效，并可管理 Certificates, Identifiers & Profiles。
2. 在 Identifiers 中确认 Mac App ID 为 `com.yingchui.interconnect.mac`，启用 **Sign in with Apple**。
3. 确认这是独立 Primary App ID，还是与其他 Apple App 分组。没有明确需求时不要自动合并其他产品的 Apple 身份。
4. 创建已关联上述 Primary App ID 的 Sign in with Apple Key，记录公开的 Key ID，下载一次 `.p8` 私钥并安全保存。
5. 提供公开的 Team ID、Client/App ID、Key ID、Primary App ID 和私钥文件路径。不要把私钥内容、client_secret 或真实授权结果粘贴到中转区。
6. Xcode 的 YingchuiMac → Signing & Capabilities 添加 Sign in with Apple，获取匹配的开发 provisioning profile；正式发布时再确认分发签名是否支持此原生能力。

当前代码只使用原生授权。不填写猜测的 Services ID 或 Return URL，不自动改用网页授权。若分发方式要求网页，需另行登记准确域名、Services ID 与回调并开发对应流程。

## 服务端配置

待接线时使用独立 `config/apple-auth.json`。代码已支持以下形状；示例保持关闭，不含可用私钥：

```json
{
  "enabled": false,
  "team_id": "Q269MU4N6F",
  "client_id": "com.yingchui.interconnect.mac",
  "key_id": "",
  "private_key_path": ""
}
```

- `private_key_path` 必须是部署服务器上的绝对路径，内容为 Apple 下载的 P-256 PKCS#8 `.p8`；限制为运行用户读取（例如 `0600`）。
- 缺文件、空 ID、错误密钥类型或不安全权限均报错，不使用样例密钥或其他账号替代。
- client_secret 在服务端按请求生成，ES256 签名、5 分钟有效；不交给 Mac。
- Apple 端点固定为 `https://appleid.apple.com/auth/keys`、`/auth/token` 和 `/auth/revoke`，正常 TLS 校验，不跟随重定向，不自动重试授权码兑换。
- Apple refresh token 必须由服务端加密保存；加密密钥需要独立安全配置，不能复用验证码摘要密钥。此存储接线目前待完成。

## 后端接线清单（开发者继续工作时）

1. 与当前邮箱实现核对 `auth_users`、`auth_identities`、会话函数和事务边界。不得从本机旧源码直接发布覆盖另一端已完成的邮箱服务。
2. challenge 使用服务端强随机 nonce，5 分钟期限、持久化、限流、原子一次性消费；数据库失败直接报错。不可采用运行时内存替代 PostgreSQL，也不可允许失败后重放。
3. `/apple/login` 只接收 `challenge_id`、`identity_token`、`authorization_code`、可选 `nickname`。不接受客户端声明的 sub、user_id、audience 作为认证依据。
4. 调用 `appleauth.Client.Authenticate` 前原子消费 challenge；使用返回的已验证 `Issuer + Subject` 作为独立身份主键，并调用现有正式业务会话签发函数。两次 Apple 身份的 sub/nonce 必须一致。
5. 姓名是未签名的可选资料，只在首次提供时校验长度/字符并保存，不作为认证依据。隐藏邮箱和没有邮箱的管理型 Apple 账号都必须支持；不能凭同邮箱自动关联历史账号。
6. 将 Apple 上游 refresh 加密保存并落实撤销处理、服务端通知校验/去重或周期有效性检查。普通业务退出只撤销当前业务 session，不调用上游 `/auth/revoke` 把其他设备的 Apple 关联一起撤销。
7. 账号删除/关联需要独立双重验证与事务；未完成前不展示入口。不能把 `appleauth.Client.Revoke` 单独存在当作完整的账号删除支持。
8. 确认完整 User/Session 结构与当前邮箱一致，补充新错误码及版本，并由中转区同步定稿契约。
9. 完成后才配置服务端 `enabled: true` 和 Mac `appleEnabled: true`。`/status.apple_available` 必须反映真实配置、数据库和集成状态。

## Mac 签名与构建

当前 Team ID / Bundle ID 如上，但运行签名没有 `com.apple.developer.applesignin`。仅修改 JSON 不会赋予 Apple 能力。暂时不要为了消除错误伪造 entitlement 或绕过检查。

配置完成后执行：

```sh
xcodebuild -workspace YingchuiInterconnect.xcworkspace -scheme YingchuiMac -destination 'platform=macOS' -derivedDataPath work/repair/mac-build build
codesign -d --entitlements :- work/repair/mac-build/Build/Products/Debug/YingchuiMac.app
```

实际签名应包含 `com.apple.developer.applesignin` 的 `Default` 值，并有匹配的 provisioning profile。Apple 私钥、client_secret 和上游 refresh 都不能打包进 Mac。

Mac 只把业务会话写入独立系统登录钥匙串。`appleUserID` 用于本机授权撤销检测，不是业务访问凭据。退出/切换/取消会使旧请求失效；刷新提交前保存待撤销标记，避免崩溃后重放旧 refresh。

## 验收

- 离线：错误签名/算法/issuer/audience/nonce、过期/未来签发、授权码替换、兑换后不同 sub/nonce、上游失败不重试、开发者签名、密钥权限、隐藏邮箱/无邮箱、挑战并发消费和会话撤销。
- 实机：本人系统 Apple 授权成功与取消、隐藏邮箱、重启恢复、退出、授权撤销、正式签名安装。
- 线上：确认部署版本、状态接口、数据库持久性、挑战限流、重放拒绝和服务失败。离线生成的测试密钥/令牌只在单元测试内使用，不进入真实服务或验收记录。

只有离线、数据库、签名和真实授权验收闭环后才能标记 Apple 登录完成。当前付费/后台步骤由用户明确暂缓，不反复催办。

## 参考

- [Apple 原生授权](https://developer.apple.com/documentation/signinwithapple/authenticating-users-with-sign-in-with-apple)
- [Apple 身份验证](https://developer.apple.com/documentation/signinwithapple/verifying-a-user)
- [Apple 身份信息与管理型账号](https://developer.apple.com/documentation/signinwithapple/receiving-a-users-identity-token)
- [Apple OpenID 配置](https://appleid.apple.com/.well-known/openid-configuration)：本机已只读获取，声明 ID token 使用 RS256；不能将 client_secret 的 ES256 算法当成 ID token 算法。
- [macOS Keychain 实现说明](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)
