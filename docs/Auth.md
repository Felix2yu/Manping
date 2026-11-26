# 原生认证链路

源码基准为 BiliCopilot `896a06290ba440cb17776d292dff119bbd3383d6` 与 NuGet `0.0.2-preview2` 声明的 BiliKernel `22fdf8ca04bab384b46536b05f6524a41f83a2d4`。Authorizers.TV/Core snupkg 的 SourceLink 指向同一 commit；本次重新比较七个认证/模型文件与本地 e26f snapshot，字节一致。`BiliApis.cs` 整体有差异，下面的 Passport endpoint 从 exact 22f 源码重读；各原文件 SHA256 见 `Dependencies.lock.json.biliKernelNuget.authenticationSource`。

| 请求 | 参数与行为 |
| --- | --- |
| POST `/x/passport-tv-login/qrcode/auth_code` | `local_id`，每个 service 一个无连字符 GUID；禁止旧 `access_key` |
| POST `/x/passport-tv-login/h5/qrcode/confirm` | `auth_code`、匹配 Passport URL 的 `bili_jct` 作为 `csrf`、手工 Cookie header；禁止旧 Token |
| POST `/x/passport-tv-login/qrcode/poll` | `auth_code`、`local_id`、每次生成的 `guid`；禁止旧 Token；86039/86101 等待、86090 已扫码、86038/-3 过期 |
| POST `/api/oauth2/refreshToken` | 旧 `access_token`、`refresh_token` 和签名参数中的 `access_key`；成功替换 Token |

所有 App POST 按 `BiliAuthenticator.Extension.cs` 添加 `build=80200100`、公开 App key、`mobi_app=iphone`、`platform=ios`、Unix 秒 `ts`，将未编码 `key=value` 排序连接并附 App secret 做 MD5，随后单独 form-urlencode。`expires_in` 是 TTL，保存时转为 Unix 到期秒并拒绝非正值及溢出。成功模型包含 `mid/access_token/refresh_token/expires_in/cookie_info`；Token Cookie name/value 映射为安全的 `.bilibili.com` Cookie，与上游 resolver 的 Bili-wide 行为一致。

`beginQR/pollQR` 保留调用签名，默认 QR 改为原 UI 使用的 TV 协议。`beginWebQR` 保留显式 Web QR 入口。`synchronizeCookies` 保存有效 Web Cookie，清除旧 App Token，调用方再以 `authorizeWebCookies` 完成 TV 确认/轮询；转换失败保留 Web 登录并明确显示“仅 Web 登录”。`ensureAppToken` 对过期 Token 做 single flight refresh，最多重试一次 transport 失败，不重试服务器拒绝。取消一个 waiter 不影响其他 waiter，最后一个 waiter 取消会取消 transport；logout 始终取消整个 flight。

REST 扩展入口 `appRESTParameters` 输出含 `access_key` 的 App form。REST 使用两种稳定、明确的客户端标识：Web REST 为 `Manping/1.0 (macOS; Native)`，Bilibili Web 域名附带 `https://www.bilibili.com/` Referer；App REST／Passport App 为 `Manping/1.0 (iPhone; iOS 16.6)` 与 `https://app.bilibili.com/` Referer。不再把 Safari桌面 UA 或 `www` Referer 混入原生 App 请求，也不向非 Bilibili 域名附加 Bilibili Referer。这是保守的协议标识，不是风控绕过；线上接受情况仍需实机验证。`AuthSnapshot` 明确区分 `needsLogin/webOnly/appAuthorized`，仅有效 Token 提供 `authorization: identify_v1 …` 与 `x-bili-mid`。原生 gRPC 模块已实现 protobuf device/metadata/network 等 header，并通过 `withRPCIdentity` 原子捕获身份、取消在途 stream 和核对响应。AppModel 与播放模型已订阅 `identityEvents()` 取消旧请求并清理旧内容；真实服务接受情况仍需实机验证，见 [RPC.md](RPC.md)。

Cookie jar 属于 service，不使用 `HTTPCookieStorage.shared` 或 `URLSession.shared`。URLSession 禁用自动 Cookie、全局 credential storage/cache/additional headers，保持系统默认 TLS 校验并拒绝自动 redirect；只有匹配 Bili domain/path/secure/expiry 的 Cookie 能手工注入，Set-Cookie 还需属于响应 host 的 Bili domain。response 接受前检查 cancellation 和 auth epoch；logout 先递增 epoch、取消任务，再清空内存及持久化。服务器错误仅展示静态说明和数字 code，不输出 secret-bearing message/body。

Cookie 与 Token 统一存入 `LocalSecretVault` 的 `bilibili.session` 条目，和代理密码一起用 AES-GCM 加密保存在 `~/Library/Application Support/im.yufei.manping/Secrets/`。应用不读取或删除原应用的 Keychain 项目。

应用只保存一个当前用户。`bilibili.session` 继续使用单账号 `cookies`／`token` 与 `proxySecret` schema；凭据和代理密钥的读取—修改—写入由同一 recursive lock 串行，退出登录只清账号字段并保留代理密钥。Web-only 登录必须具有唯一正数 `DedeUserID`；Token 与 Cookie MID 冲突会被拒绝。恢复先在独立 Cookie jar 中完成合并和身份校验，通过后才替换运行态；冲突或非法 Web-only 凭据不会改写当前身份、epoch/revision 或持久化条目。

WK 使用 `.nonPersistent()` data store；dismantle/logout 关闭 sheet 时取消 callback/task 并清理该隔离 store。AppModel 的 generation 和 service epoch 双重拒绝迟到登录结果。

验证：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`，认证 fixture 33 项；完整 Core 855 项（5 个 opt-in live/FFmpeg test 跳过）与 App 141 项，合计 996 项、0 failures；本轮修复文件 `swift-format lint --strict` 与 scoped `git diff --check` 通过。最终 Debug 包 `--ui-model-checks` 的 11 组检查全部通过，覆盖身份变化后的停放/前进、迟到重试和直播取消加载释放。fixture 验证 fake-key 签名向量、form、TTL/溢出、QR 状态、无末尾分号 CSRF、refresh single flight/有限重试/cancellation、持久化纯编解码、Cookie 过滤、logout 与迟到 request/QR/refresh/WK Cookie/account、UI callback generation。WK 实机登录、Token 在 LocalSecretVault 中的存取和恢复、真实 TV/refresh endpoint 仍未验证；没有钥匙串操作或发布账号内容。主 agent 已在旧 `dist/gate` 确认用户手动授权后的旧 Cookie 重启恢复，这不构成新 Token 链路验证。

独立 review 修复：身份替换使用独立 `identityRevision`，不改变当前 QR epoch；旧 refresh 的成功、失败和 Cookie 接收均被隔离。Web QR 成功与 WK Cookie 同步统一先取消旧 flight、清旧 Token，再提交新 Cookie。TV Token 提交遵循相同顺序，Token 写入失败保留新 Web Cookie、内存不恢复旧 Token；旧 Token 清除失败不写新 Cookie。存在 `DedeUserID` 时提交及恢复均校验 `token.mid`，拒绝混合身份。waiter 的取消检查与登记在同一锁中原子执行，旧 flight 清理仍检查 flight identity。新增受控测试覆盖 A→Web QR B、同 epoch A refresh 迟到成功/失败及其对 B App Token 的影响、Token 第二次存储失败、旧 Token 清除失败、恢复一致性、混合身份恢复失败时运行态与存储均不变和 last waiter 取消/新 waiter 登记的精确线程交错。真实 OS prompt 取消路径尚未验证。
