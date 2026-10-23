# Mac 后台管理与更新协作

## 2026-09-14 统一自动更新客户端交付

用户回复“开始更新”后，已在实际主工程完成新需求 platform-mac-automatic-flow-20260914-01。独立启动/300秒检查、自动下载、空闲延期恢复、固定版本撤回复核、安装前网络预留、退出期间取消保护及真实版本完成回报已接入；公开更新不依赖登录，认证心跳不再携带推送任务编号。生产代码使用公开 Sparkle API，自有调度器负责300秒周期，框架双重调度关闭。实现与验证说明见 work/repair/mac-management/automatic-delivery.md。

当前制品 **1.0.7/构建11** 已自动上传并独立确认 draft；release_id=abf5bd50fdc451ed9a9d9825fda9cc0d64af9e8431ff6242d83503c283bacf90。包位于 artifacts/mac-updates/build-11/package/Yingchui-Mac-11.ycu。新包 channel=unified、实际客户端 automatic_updates=true；双层签名、摘要长度、篡改拒绝和解包代码签名均通过。Mac Debug/Release配置同步1.0.7/11，避免Xcode以旧构建号启动新代码后再安装旧版本。源配置变更没有替换当前运行应用。

37项客户端、43项打包上传测试通过，日志automatic-final-tests.log与automatic-python-tests-4.log；设置离屏验证通过。公开status已返回automatic/300/空闲安装策略，统一真实架构/系统源200；构建11固定源404符合待发布。后端14:17的未部署说明已被公开实测更新，不能再称接口仍未开放。未修改真实后端/部署工具文件、部署服务、替用户发布或安装。

新自动升级闭环仍待：用户发布构建11→旧客户端一次过渡安装→发布更高版本验证实际后台下载/延期/安装重启/版本心跳。旧构建7的交互验收不代表新流程已完成。开发签名与未公证状态如实保留。当前未恢复此前已暂停的定时检查。

交付中转消息 msg_1789368641220_e9d200627667911140447f7a 已HTTP201并独立回读确认；附件yingchui-mac-automatic-build11.zip，3701428字节，SHA256=fc0b956bd936de4672cd938393c0288fc34f07170e60db4d5a23be5f177430be，61个文件及摘要清单。首次正文被接口400拒绝，精简正文后同一请求编号成功，未生成重复消息。

## 14:07 修复更新提示的版本说明持续转圈

用户截图显示1.0.3提示安装1.0.5，中间版本说明区域持续加载。线上appcast与releaseNotesLink均返回200，说明内容215字节正常；根因在客户端：shouldDownloadReleaseNotesForUpdate返回false，但未配置SUShowReleaseNotes，Sparkle 2.10.0仍根据清单中的说明地址创建加载指示器，等待永远不会发起的说明下载。已在Info.plist添加SUShowReleaseNotes=false，与现有下载策略一致；保留原生安装操作及真正的下载进度。当前旧版本提示仍可直接点“安装更新”，无需等待版本说明。

22项更新中文与定向任务测试通过。离屏验证脚本verify-release-notes-window.swift使用当前线上清单、真实Sparkle原生弹窗及新旧应用Bundle：旧窗口532×370且1个加载指示器；新窗口532×124且0个；两者安装、稍后提醒、跳过三个按钮回调均通过。验证仅调用界面驱动，没有启动更新器、下载或安装。日志与画面为work/repair/mac-management/release-notes-before/after.log和.png。测试工具使用固定组件版本的只读activeUpdateAlert入口与仅供布局验证的清单初始化方法，未加入生产代码。

修复版1.0.6/构建10已自动上传并独立核对版本记录，状态待发布；release_id=40839deac20819b18e25ef3c5348d801664952c8722c5f6fb81a0484f926590a，包为artifacts/mac-updates/build-10/package/Yingchui-Mac-10.ycu。签名制品Info确认SUShowReleaseNotes=false。尚未发布、推送或安装；旧客户端升级到此版本后，后续更新提示才使用修复后的布局。无需后端修改，不恢复中转区定时检查。

## 13:52 移除检查更新后的版本历史记录入口

按用户要求，MacUpdateController 接入 Sparkle 标准界面代理，关闭检查更新结果中的“版本历史记录”按钮。保留中文提示、确认按钮和原生安装流程。隔离目录编译及现有5项更新中文测试通过；自动生成1.0.5/构建9并上传成功，服务器版本记录核验通过，状态为待发布，尚未发布、推送或安装。

更新包：artifacts/mac-updates/build-9/package/Yingchui-Mac-9.ycu；release_id=c5b7b41a8a998fdd5258cf7fc214723c8e94b2b7e0d4084dcd977dcbcebb1e62。包含构建8的收尾修正。生成日志为work/repair/mac-management/remove-version-history-package.log；检查仍暂停，此项不需要后端修改。

## 12:30 主线真实升级验收通过，收尾修正已上传

收到 platform-mac-build7-installed-reconcile-20260914-01（msg_1789359433091_6929260ad507612dbdb079e9）及后续 platform-mac-build7-job-completed-20260914-01（msg_1789359718873_f39ffdb83a708a9dfc9c5c4d）。已在本机独立核验真实运行进程45642、1.0.3/构建7、beta；可执行文件SHA256与已签名构建7一致，完整codesign验证通过。系统日志记录12:15:45.784更新器从下载缓存解压归档、12:15:45.948 EdDSA签名通过、12:15:47.157旧进程正常退出、更新器通过系统启动新应用、12:15:49.023新进程启动、12:15:51.677真实已安装心跳。原生交互安装且自动下载安装关闭；现有日志没有独立记录按钮点击时间，不虚构此证据。

独立后台核验任务edcb8adf-0499-44df-814e-0fa730da476b为completed，完成时间12:20:54.125912；同一账号及安装编号，任务持久化文件按终态正常清理。**原主线实际升级已验收，不再重复推送构建7，不再描述为仍待实机验证。** 完成延迟一个300秒周期，是首次已安装心跳尚无任务编号，响应才下发已安装目标；下一周期才回传带编号installed，不是丢失状态或需要改库。

已修正这两个实际发现的收尾问题：MacUpdateJobTracker判断是否需要补报完成，MacManagementController仅对真实已安装且本次尚未发出同任务installed的情况立即补报一次，之后恢复正常间隔；MacUpdateController对真实已安装目标阻止重复检查，并把无新版结果保留installed而非错误1001。33项Mac专项通过（含迟到任务仅补报一次、换号/未安装保护和已安装结果不误报），测试在隔离derivedData执行，没有用项目默认构建1覆盖运行中的构建7。

收尾改进已通过自动入口生成并上传 **1.0.4/构建8**，状态draft，release_id=f6fb54c217bd4d8a50ab8a3cb975f395b5c096800d46463803a9787997ce04c8。包在artifacts/mac-updates/build-8/package/Yingchui-Mac-8.ycu。当前实际运行仍为1.0.3/构建7；构建8未发布、未推送、未安装，由用户选择后续发布。不能把构建8修正说成正在运行的构建7已有。

最终验收交接real-upgrade-accepted.json，request_id=yingchui-mac-real-upgrade-accepted-20260914-21；附件yingchui-mac-final-acceptance.zip SHA256=851d9285fc409b1093ba9a650ebd47a0f6dd1f7f53e5005b2b5cc79d95809770，25834字节，含真实安装证据、修正源码、33项测试和上传回执。发布并独立回读后记录两条后端消息已处理，按原任务约定暂停mac-2检查，不重复确认纯收件回执。最终状态以processed-messages.json及automation.toml为准。

## 12:15 当前电脑切换测试渠道，等待真实推送安装

收到 platform-mac-switch-beta-authorized-20260914-01（msg_1789359132866_37a6983e32166d1e6c295762）：用户在部署工具明确选择让当前电脑接收测试版本，授权来源为中转区同一联合开发链。**此前保持当前stable、必须独立测试实例的限制已被本次用户选择取代**，不要重复索要切换授权或要求另一台电脑。目标1.0.3/构建7已由用户发布，不能再把该版本描述为待发布。

先独立读取实际设备streaming=false，再把源MacManagementConfiguration.json的channel改为beta，Info.plist默认SUFeedURL改为beta。MacManagementConfiguration派生实际arm64 feed以及MacUpdateJobTracker验证都使用同一beta配置，不是只改心跳标签。正常主应用编译与完整codesign通过，保留1.0/构建1更新起点，未直接安装构建7。重启进程45525，04:14:57.623Z真实认证心跳成功；独立GET devices确认同一user_id及installation_id=758497b5-6a12-4d7e-bc47-de3a9dedb027、beta、1.0/1、online=true、streaming=false、idle。证据beta-switch-before/after.json、beta-switch-build1.log、beta-switch-restart.log及runtime.log。

已准备 beta-switch-complete.json 回执（request_id=yingchui-mac-beta-switch-complete-20260914-20），发布及独立回读完成后以processed-messages.json为准，通知后端按用户推送意图重试同一已发布构建7并回传任务编号。保留原生用户确认安装，不替用户点安装，不把渠道切换当成升级成功。下一步接收任务、核对真实版本变化及完成心跳；仍不暂停mac-2检查。

## 12:05 后端独立线上验收确认

收到 platform-mac-ingest-live-accepted-20260914-01（msg_1789358458337_d72039f86f1bc76807a9d3a1）。后端只读独立核对1.0.3/构建7的测试渠道待发布记录唯一、uploaded审计1、published审计0、相关任务0、公开feed不含该制品，并核对客户端上传/原包重试证据及交接ZIP摘要。自动打包后上传需求双方已按真实线上范围验收完成，不需要用户再发布后端。

对方明确无需回复本核验记录，无新代码或接口要求，本轮只记入 acknowledgements，auto_upload_accepted=true、backend_verified_beta_build=7，不重复发送确认，不编译或发布新包。原主线实机同渠道更新安装仍单独待验收，继续保留五分钟检查。

## 11:54 自动生成后上传：线上真实验收完成

用户新增“生成之后自动上传到鹰锤 Mac”。已新增 scripts/mac-updates/upload_client.py、upload_update.py、重试上传更新包.command，并接入 build_update.py 默认生成流程。使用 Python 标准库固定 HTTPS POST /api/yingchui-mac/ingest，原始 .ycu 正文，不使用额外凭据、环境变量或旧 /bundle；失败报错保留原包，原子写每包 .upload.json。再次双击生成入口优先重试未完成上传，也可 --upload-only 指定文件，不重新编译、不递增版本。带新版本说明且存在待上传包时明确报错，不静默丢弃新参数。

后端 platform-mac-ingest-contract-20260914-01 / platform-mac-ingest-delivery-20260914-01 已收到；附件 SHA256=cbe6bc3fec973e6577ff235886b0663147b4b1c08be5f487cfb8a2b8c9bcc1fc，9个交接文件摘要通过，仅解包在 work/repair/mac-management/auto-upload-backend，没有改部署工具/后端文件。接口随后真实上线：GET ingest 从404变405，POST 成功。因此**不要继续告诉用户需要发布后端或配置上传凭据**。

41项Python专项通过，含完整入口顺序、签名凭据与重试分离、断网/超时、摘要错误、幂等响应丢失、撤回、冲突及状态落盘。正常用户打包进程37752持锁，采样确认仅停在PyOS_Readline且无子任务后安全SIGINT中断，随后由新版入口真正生成 **1.0.3/构建7** 并自动上传；此阻塞已解决，不再让用户关闭旧窗口。

实际新包：artifacts/mac-updates/build-7/package/Yingchui-Mac-7.ycu，包含刚才的更新弹窗汉化，应用内显示版本1.0.3、构建7、简体中文和完整codesign验证通过。发布历史现在已到7，不能再硬编码默认构建6。正常运行的主应用没有替换为测试包。包摘要 f1bbac5645072fff9b39a8e2055194e7f93a61650401d5dc23f4fd7b52df7396；release_id/归档摘要 34686d29a82b249ac3f0e8075bc2d3d135bbbeb101191f52d41355c28d2668a5；原始元数据摘要 59b559e1a2ffc3ff213e11da00c1111bbc0d589ecef0c4ab4bbfe0eaa32bae73。

首次自动上传及第二次 --upload-only 原包重传均成功，第二次 already_exists=true；成功历史未变化，独立GET releases核对签名元数据及单一draft记录，审计仅一次uploaded、没有published、没有相关推送任务，公开测试渠道feed不含该制品。线上自动上传已经验收完成；不是仅编译或隔离测试通过。证据 auto-upload-build7.log、auto-upload-retry7.log、auto-upload-live7-proof.json、auto-upload-tests-final.log。部署工具中已可查看1.0.3（7）待发布，由用户选择发布和推送。

最终客户端交接 auto-upload-client-ready.json（request_id=yingchui-mac-auto-upload-client-ready-20260914-19）包含脚本/测试/配置与线上证据ZIP，附件 SHA256=582c3ac5c94d33b94c96ef6984fc785281fa0e3847ff82f1e36534519874579d，28255字节；发布回读完成后记入 processed-messages.json。不需要就纯收件确认反复回复。**原主线同渠道实机下载/替换/重启/完成心跳仍待验收，不因为自动上传完成而暂停 mac-2 检查。**

## 10:18 检查：自动版本交付已由后端验收

收到 platform-mac-autoversion-accepted-20260914-01（msg_1789351942669_4883137f307b99ddfcb732ae）。后端独立核验构建5交接ZIP/.ycu/归档摘要长度、双层Ed25519和篡改拒绝，并直接读取归档内.app Info.plist，确认1.0.1/build5、beta渠道及更新说明与签名metadata一致。已归档实际入口、历史模块、配置、README并通过语法检查。

部署工具已确认直接读取metadata.app_version/app_build/release_notes，无需改服务或重复部署；未向生产上传此包，不能说线上已发布1.0.1。用户的自动带出版本、构建自动递增、只填写说明这一项需求已经验收完成。实机同渠道更新安装仍单独待验收，整个Mac管理联合开发不能宣告完成或暂停。

这是对完整最终交付的确认，无新请求；对方明确无需重复确认收件，遵循双方此前避免重复回执的约定，本轮只记账并同步用户，没有再发外部确认。processed-messages.json新增acknowledgements存储该已处理回执，backend_verified_beta_build=5、autoversion_accepted=true。**后续筛选未处理消息时同时排除replies和acknowledgements中的ID**，不要把已处理确认重复当新需求。读取其它字段为上下文而非未读列表。

## 09:50 检查：自动版本需求已实现

收到 platform-mac-autoversion-request-20260914-01（msg_1789350390065_57a8ccd7a7244539409cffdc）：用户实际双击后要求自动填写下次发布版本号，构建号自动递增，主要填写更新说明。本轮已直接修改 scripts/mac-updates/build_update.py 并新增 release_history.py 与 tests/test_release_history.py，不是只补说明。双击入口不变；新CLI支持--version/--build/--notes，只有--notes即可自动选两个版本。

版本来源：通过plutil解析真实Mac应用Release配置的MARKETING_VERSION与CURRENT_PROJECT_VERSION，结合成功.ycu和artifacts/mac-updates/release-history.json计算；显示版本三段补丁+1，构建号高于所有成功历史及占用/失败目录。不会覆盖已有产物。全程fcntl跨进程锁保护共享构建目录；失败attempt.json只占用构建号，不推进成功版本；成功字段/摘要核对后才fsync及os.replace原子提交记录；损坏、重复、冲突及完成制品未提交的历史都明确报错，无伪造初始版本。

18项Python专项通过，日志autoversion-tests-final.log；包含连续递增、显示版本覆盖、构建失败/原子提交失败、记录保留、损坏/重复/冲突、并发锁和交互。完整真实打包已生成 **发布版本1.0.1、构建5**，artifact路径 **artifacts/mac-updates/build-5/package/Yingchui-Mac-5.ycu**，应用在同级staging/YingchuiMac.app。actual.app、metadata.app_version/app_build、release_notes和包一致。正常stable应用和项目源版本没有改变，未重启/替换它，未上传生产或安装。

新入口的真实PTY验证：再次运行.command显示“发布版本号 [1.0.2]：”，回车后“构建号：6（自动）”“更新说明：”；Control+C显示“已取消打包。”并退出130，没有创建build6或改变成功记录。用户旧Python进程29713先前停在旧提示，已告知需要Control+C后重新双击以加载新程序，没有终止用户进程。不要再告知用户默认构建5，现有成功记录已推进到5，下次正常应建议1.0.2/build6（以后继续以真实历史计算）。

构建5仍beta/arm64/macOS15.0.0起/Apple Development、两个verified=false，Mac业务代码与build4一致，本轮变更在打包工具。ycu SHA256=22f3485f0416d48bd764ee32ebd0a2d6e706f2994a79273e56ecc3a16dadc929，3664575字节；内部归档SHA256=12cf1c36c2622151668604620cb401b356a3b3fc305776448bb7dec9e1b90f69，3663515字节。两层Ed25519、摘要/长度/版本说明一致、篡改拒绝、解压codesign均通过；证据autoversion-build5.log、autoversion-build5-proof.json、autoversion5-signature.log、autoversion5-unpacked-signature.log。

autoversion-progress.json已HTTP201且回读确认（msg_1789351186060_6436149fe37878e25272eb8c）。最终autoversion-delivery.json request_id=yingchui-mac-autoversion-delivery-20260914-16，附yingchui-mac-autoversion-build5-handoff.zip（3573359字节，SHA256=b8049b69b3f18b267642ec1192c091066586db6112ec1de34044df33e18bf0fb），含更新包、实际脚本模块/双击入口/配置/README、测试和验证记录。发布是否完成及独立回读以processed-messages.json为准。

下一步接收自动版本脚本/构建5交接回执，确认管理端直接读取包内显示版本/构建号/说明。仍未完成实机安装，独立beta实例或正式签名条件没有新增，不暂停五分钟检查。

最终自动版本交付已HTTP201并独立回读确认，消息msg_1789351490692_77f44b25425719ab178d466c，附件存在，processed-messages.json已记录最新本地beta构建5，后端独立验签目前仍到4。后端在最终交付前发来的platform-mac-autoversion-progress-20260914-01（msg_1789351438202_5edd6069b7ebc6a4dc1c2214）只确认进度并等待最终包，已被上述完整最终交接覆盖；记录其对应回复为该最终消息，不重复发确认造成往返。

## 09:42 检查结果

后端 platform-mac-build4-received-20260914-01（msg_1789350007950_d0aebbb513c89e9483646218）已独立核验构建4的交接ZIP、.ycu、归档摘要长度、双层Ed25519及篡改拒绝，归档全部打包入口并核对Python语法，明确构建3已被替代。本轮仅记录验收和回复，没有改代码、重跑测试、重启应用或发布生产制品。

我方build4-validation-ack.json（request_id=yingchui-mac-build4-validation-ack-20260914-14）已HTTP201发布并独立回读，processed-messages.json已记账。明确无需回复本次纯确认，后续只同步可行动变化，避免双方无限重复回执。

当前无新增接口需求。源码专项25项、真实登录心跳、管理端在线记录和构建4制品双边验证均已完成；同渠道实机下载/确认/替换/重启/完成回报尚待验收。用户需要提供可用独立beta测试实例，或正式Developer ID签名与公证条件。不得在当前用户下启动同bundle副本伪装独立实例，不擅自创建macOS用户、替换正常stable或生产发布测试包。五分钟检查保持ACTIVE，未到联合开发完成；无新消息/可行动变化时保持安静，不重复通知这些已知条件。

## 最新接续状态（09:03 检查，工作持续至09:34）

**最终制品已递增为beta构建4，构建3不是最终交付。** 最后修正安装前复核失败时停止任务并保留failed回执，避免原生取消回调把失败覆盖成延期；25项专项通过（8管理+14任务+3界面/委托），证据targeted-install-failure-tests.xcresult/.log。正常应用已再次编译重启，当前进程28863、stable/build1，09:31:37真实认证心跳成功；证据targeted-build4-normal.log、targeted-build4-restart.log及runtime.log。

后端 platform-mac-package-howto-20260914-01（msg_1789348953385_15b5eab09bbf43b8000f1b04）确认线上和内部代理均200，无需重复部署；并转来用户询问如何生成更新包。已新增 scripts/mac-updates/生成Mac更新包.command、build_update.py、build-config.json、README.md，可双击后只填递增构建号及更新内容，也可命令行 --build 5 --notes '更新内容'。入口当前明确只生成beta；正式签名/公证未就绪时不伪装stable。官方sign_update原始二进制已复制到Mac/Vendor/SparkleTools（许可证在上级），不依赖work暂存工具，不导出私钥。

打包入口已真实完成构建4的Release编译、隔离beta配置、重签及.ycu输出；首次构建因Xcode destination与-arch冲突失败，已修正，失败日志保留在artifacts/mac-updates/failed-build-4-destination，不能把这次已解决的问题继续当阻塞。构建日志artifacts/mac-updates/build-4/build.log，入口日志beta4-build-entry.log。产物 **artifacts/mac-updates/build-4/package/Yingchui-Mac-4.ycu**；应用在同级staging/YingchuiMac.app。后续构建号从5或更高开始。

beta4：1.0/build4，arm64，最低macOS15.0.0，Apple Development，developer_id_verified/notarization_verified=false。ycu SHA256=963d91cf1868418880bc8f20b5bef7d7fc6c1b57219a21f06fa0c169a3364a82，3664634字节；内层归档SHA256=0c98e8cc2e7c3f178845080459074892ac9cf3df30acc168bb48099a9aae59eb，3663514字节。原始三文件ZIP结构、双层Ed25519、摘要长度、篡改拒绝和解压codesign均通过，beta4-verification.log及beta4-unpacked-signature.log。未生产上传、未真实替换安装。

beta4-howto-handoff.json 以request_id=yingchui-mac-package-howto-beta4-20260914-12回复上述打包问题，附带yingchui-mac-beta-build4-handoff.zip（3564533字节，SHA256=a1d20e2c61e0be04c3589cc97e0d6e67773eecdf0af6a6e8acd86c66ee6ea83f），内含新.ycu、两级打包脚本、配置、双击入口与README。是否发布/独立回读完成以processed-messages.json为准。构建3此前回读确认消息msg_1789349124858_8b368b0f9885b384d3076f32。

构建4上传已HTTP201并独立回读确认，消息msg_1789349665974_66641a7f63e9c4c81b26a374，processed-messages.json已记录。上传完成前曾过早回读未发现消息，随后等待成功并再次独立回读已解决，没有重复上传。

后端 platform-mac-build3-received-20260914-01 已独立验签构建3，并确认管理平台已有1台设备、1台在线、stable/build1。我方以beta-receiver-guide-reply.json（消息msg_1789349774254_118c5e13c6cb0b28db1cabd5）回复其与新包交错的打包问题，指向构建4及双击入口；回读已确认。README增加独立beta接收说明：另一台已配置开发签名条件的测试Mac运行build4并登录，管理端出现独立beta/build4记录后再生成build5定向验收。当前用户不能直接运行第二份同bundle应用当独立实例，会共享安装/账户；未创建macOS用户或替换当前stable应用。没有测试环境时真实安装仍待验收。正式分发仍缺Developer ID和公证。

继续等待构建4包联调与同渠道真实安装验收；管理端真实Mac上线已经确认，不必重复要求此回执。正常stable客户端不能收beta，仍不得宣告联合开发完成或暂停自动化。以下为本轮前面阶段细节，版本/进程/数量均以上文为准。

已处理 platform-mac-homenas-flow-20260914-02 与 platform-mac-homenas-delivery-20260914-01。后者附件 yingchui-mac-homenas-flow-20260914.zip 的SHA256=36ed7095d2f7028c710dc78ca95bfed141c5b95065157561ce6c8c946ce15c53，ZIP完整性及清单31项摘要均通过，只解包在本项目 work/repair/mac-management/homenas-delivery，没有修改真实后端或部署工具。最终契约见该目录的 DevicePlatform/Platform_Backend/docs/yingchui-mac-management-v1.md。

**线上已可用，不要继续说503或要求重复发布。** 09:20探测 status HTTP200，management_available/updates_available/push_available均true，beta/arm64 feed为合法空RSS。证据deployment-probes-0920.json。正常Mac已编译更新并重启，当前进程27773，正常stable构建1，09:21:45真实认证心跳成功。日志targeted-normal-build.log、targeted-restart.log及用户应用支持目录的Diagnostics/runtime.log。后端交接文档中“尚未发布”落后于线上实测，已通过中转回执提醒对方核对部署状态。

定向任务已实现：MacUpdateJob严格校验小写UUID v4、SHA256、构建号、同源同渠道同架构固定feed；MacUpdateJobTracker按当前用户及安装实例持久化update-job.json，退出/换号不发送别人的任务，重启先同步后台，installed仅按真实构建达到目标判断。status.push_available=true才发送update_job_id；409 invalid_update_job明确报错并清理本地任务。null/终态取消任务；任务固定build与归档SHA路径匹配，不改装其他版本。

MacUpdateUserDriver继承Sparkle原生界面，通过一次性回调取消等待确认/下载/安装；账号或任务失效后拒绝旧回调。MacUpdateReleaseAvailability在确认下载及安装前无缓存复核固定feed，410拒绝安装。回传中延期，稍后/取消不遗留退出时自动安装；停止任务后跨重启也不自动回到通用feed，用户明确点击手动检查才允许通用检查。修复正常空feed的noUpdate错误1001被误记失败。

最终24项专项通过（管理8、定向任务13、设置/原生委托3），证据targeted-delivery-tests.xcresult及.log；正常构建和完整codesign也通过。没有进行真实Sparkle替换应用验收，不能把这些测试当全链路安装完成。测试只用隔离的内存服务/临时目录，没有伪造生产数据。

新版单包由 scripts/mac-updates/yingchui_mac_release.py 生成：beta-release-3/Yingchui-Mac-3.ycu，1.0/build3、arm64、macOS15.0.0起、beta渠道，应用包含上述新代码。ycu SHA256=6861522d6048b532fa431192827495aa69cffe61853ed2a143b0610f9932a4ee，4413595字节；内层归档SHA256=b31bc48f2bb0cbb6669f69a00685ea904ce5247c9a29f350be3293224a3bcec0，4412390字节。恰好三个普通根文件，原始元数据/归档两层Ed25519、摘要/长度、篡改拒绝和解压应用签名均通过（beta3-verification.log、beta3-unpacked-signature.log）。签名仍Apple Development，两verified=false；未上传生产或安装。脚本已同步后端.ycu版本，并补充显示版本64字节、元数据16KiB、总包257MiB限制。

新版制品由beta3-handoff.json上传relay附件yingchui-mac-beta-build3-handoff.zip，request_id=yingchui-mac-targeted-beta3-ready-20260914-11；outer ZIP SHA256=3f9f81e9e60f114463e42fcbead7f8edc4d37b4350b9425d40c2a68b137b24b3，4299147字节，含.ycu、交接说明与脚本。发布后必须独立回读，以processed-messages.json确认是否完成。后端两条新消息的回复也已独立回读并记账。

下一步：继续五分钟检查，接收新包验签/上传与管理端当前Mac记录回执，推进真实定向安装验收。正常客户端stable不能接收beta任务；真实beta验收需同渠道测试实例，正式stable制品需Developer ID签名和公证（本机当前没有，不能伪造）。不要扩展iPad或iOS管理；用户最终仅要求Mac。不要暂停定时检查，也不要宣告联合开发完成。

实现参考：Sparkle2.10.0 SPUUserDriver头文件和官方源码 https://raw.githubusercontent.com/sparkle-project/Sparkle/2.10.0/Downloader/SPUDownloader.m 。Sparkle将HTTP失败包成下载错误，客户端另行在用户确认前检查真实HTTP状态；任何已失败的定向更新停止继续尝试，等待下一次心跳终态确认。

## 前一阶段记录（08:44，当前状态以上文为准）

已收到后端完整交接 platform-mac-management-delivery-20260914-01，附件 ZIP 与29文件摘要通过，解包在 work/repair/mac-management/backend-delivery，未修改真实 Deploy_Tool/Platform_Backend。最新完整契约要求小写UUID v4、构建号1–3段/每段18位/无前导零；客户端已修复这两点，8项管理专项通过，正常stable构建1已重启（进程22116）。测试证据contract-alignment-tests.xcresult。

重要：后端随后转来 platform-mac-homenas-flow-20260914-01（msg_1789346941983_08581ee593f963eaa5a6b80f）：用户要求复用既有HomeNAS/服务器SSH管理链路，取消额外管理账号和手工密钥配置，上传单个.ycu包、选择版本与Mac、推送并查看结果。**不要再让用户执行下面旧文档中的手工账号/两份配置步骤。** 后端正负责新自动配置和界面，不由本任务修改部署工具。线上status及四个feed现在均503 mac_management_unavailable（管理尚未配置），已经不再404；证据deployment-probes-0844.json。

定向推送拟追加：status可选push_available；heartbeat请求可选update_job_id，响应update_job=null或{job_id,release_id,app_build,state,appcast_url}。只在push_available=true时发送新字段，旧后端拒绝未知字段。任务须隔离当前用户+安装UUID，退出/换号取消旧回执，installed只根据真实当前构建达到目标判断。客户端尚未实现这些新字段，等待后端最终格式与状态枚举、固定任务feed路径、取消/撤回/重试和渠道规则后接线。已通过targeted-push-ack.json提问并建议feed固定release/build，不能误装另一次发布；默认不跨渠道。iOS管理范围由对方另行确认，本任务未擅自扩展。

已生成实际beta测试制品1.0(build2)/arm64/macOS15.0.0，应用内beta配置，Apple Development签名，未公证如实标false。正常运行客户端仍stable构建1，没有安装beta或上传生产。三个上传文件在beta-release-2，归档SHA256=767fe84210f41eec533ec85dda8413289c0af12b30990951aa6aa36c641a0542，4319569字节；归档/原始元数据两层Ed25519签名、摘要长度、篡改拒绝及解包codesign均通过。beta-verification.log与beta-unpacked-signature.log为证据。beta包内客户端尚不支持新定向任务，不可当最终定向安装验收。

真实材料已通过beta-handoff.json上传中转附件yingchui-mac-beta-build2-handoff.zip（HTTP201，已独立回读确认，消息msg_1789347085621_d169f8c1e54ee2b1aa961ef7）；outer ZIP SHA256=d49f7796c78c646766bdd01564f48a06240b8ce58f1118458fa7dd88612e4050。包内含本项目scripts/mac-updates/yingchui_mac_release.py，修复系统Python3.9不支持hashlib.file_digest并校验应用渠道与发布渠道一致，改动已回传。后端正提供.ycu新版格式，待收到后调整，不自行猜格式。

## 前一阶段记录（08:30，当前状态以上文为准）

客户端第一阶段已经实现并通过20项测试（Mac管理7、原生设置/Sparkle委托/状态3、账号会话10），正常构建及完整签名校验通过，已重启正常Mac版本，进程21045。尚未进行生产心跳和真实更新安装验收：业务status于08:30仍返回404，后端明确开发中。定时检查mac-2 ACTIVE，每五分钟在本任务跟进，有新消息回复并同步，无变化安静；不得此时暂停或宣告联合开发完成。

用户只允许通过中转区协作，不改Deploy_Tool/Platform_Backend文件。禁止Git、环境变量和截图权限请求。

## 已实现客户端

- Mac/YingchuiMac/Management：status/heartbeat请求，复用统一账号会话与禁止重定向的HTTPS传输；随机安装UUID以应用支持目录JSON持久化，损坏报错不重新生成；登录后心跳、退出/换号取消旧请求及旧响应，300秒默认间隔、接受60–3600秒服务器间隔。
- Mac/YingchuiMac/Updates：官方Sparkle2.10.0，Vendor源码包SHA256已核实；无Git下载。手动检查和定期检查、从心跳感知新版本、同源版本化制品URL校验、Ed25519归档校验、回传中延期安装/重启并在设置里继续、九种update_state。禁止自动下载安装，无任意命令。
- 公开配置MacManagementConfiguration.json默认stable；按实际arm64/x86_64选择feed /updates/yingchui/mac/{channel}/{architecture}/appcast.xml。旧universal URL仍为Info.plist初始值，运行时委托用实际架构覆盖。
- 设置新增检查更新行，保持现有通用组件；离屏排版检查已完成，图片work/repair/mac-management/settings.png。
- 当前Mac版本仍1.0(build1)，新可发布构建必须递增。

## 签名与待本人操作

SUPublicEDKey=Sr9FgKNcKqu40hbLXF2Rje/uCDjVn5ks81hsRX13PKY=，已通过中转区交接并独立回读。
私钥已由Sparkle generate_keys存入本机钥匙串account=com.yingchui.interconnect.mac.updates，未导出。
首次sign_update钥匙串授权已经完成，session21973正常退出。随后使用CryptoKit公钥独立验证原始JSON字节签名通过，增加一个字节后被拒绝，最终证据为work/repair/mac-management/signature-verification-final.log。此前曾因签名文件未产生而提前验证失败，已解决，不应继续当作阻塞。不要重复索取钥匙串授权，不导出私钥。
本机只有Apple Development证书，无Developer ID Application；beta契约允许开发签名，但stable必须Developer ID及公证，两者须由正式发布凭据完成。不要伪造校验记录。

## 后端已确认

消息msg_1789345080244_847dc7605056bc1d5dbb5b30确认mac-management-v1，固定X-Client-ID=com.yingchui.interconnect.mac，Bearer仅心跳；UUID随机，user_id从认证推导；300秒心跳，900秒离线；channel stable/beta，update_state idle/checking/available/downloading/downloaded/deferred/installing/installed/failed。没有发布返回真实空feed；最新撤回不自动退回旧版本，下载410。
消息msg_1789345795699_7c12c4cc018e573042eaade7：元数据Ed25519签附件原始UTF-8字节含换行，不能重新序列化验签。制品使用Sparkle sign_update。multipart artifact/metadata/metadata_signature，最大256MiB。字段bundle_id,app_version,app_build,minimum_system_version(三段),architectures,channel,release_notes,sha256,size_bytes,filename,ed_signature,developer_id_verified,notarization_verified。stable两verified必须true，beta可false但Ed25519必须有效。制品和说明同源chongyang.asia，路径artifacts/{sha256}/{filename}、notes/{sha256}.html。未使用SURequireSignedFeed，后端不持私钥。后端承诺发最终契约、错误样例、发布机脚本及部署回执，尚未收到。

## 中转区读写

work/repair/mac-account/tools/bin/python work/repair/mac-management/relay.py read；读取relay-current.json，messages新到旧。publish传JSON文件，记录receipt，发布后独立read验request_id/id。processed-messages.json记录已回复信息。已发布contract-ack、公钥handoff、architecture-ack，均回读确认。

待办：接收后端最终交接/部署；核对错误及心跳响应（latest_build为null或数字点分版本，有更新时必须非空）；真实已有登录会话心跳不泄露token，退出停止；测试空feed、发现更新、撤回、签名包及安装恢复。收到后端发布脚本后制作beta制品验证，生产stable仍需Developer ID公证。不得把隔离替身或编译成功当生产验收。

最新客户端回执：work/repair/mac-management/client-ready.json，request_id=yingchui-mac-management-client-ready-20260914-05，发布HTTP201，需以独立回读确认记录为准。最终测试tests-final.xcresult，正常构建delivery-verified.log，正常重启restart-final.log。当前仅后台未开放日志，不再把未部署误报为安装失败。
