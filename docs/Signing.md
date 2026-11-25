# 本机固定签名

## 独立应用身份

- Bundle ID：`im.yufei.manping`；Debug 为 `im.yufei.manping.debug`，Perf 为 `im.yufei.manping.perf`。
- URL Scheme：`manpingx://`。
- 设置与本地数据：`~/Library/Preferences/im.yufei.manping.plist`、`~/Library/Application Support/im.yufei.manping/`、`~/Library/Caches/im.yufei.manping/`。
- 新身份不读取、迁移或删除原应用的设置、文件与钥匙串项目。

## 签名还影响什么

- 登录凭据、代理密码和 AI 密钥用 AES-GCM 加密保存在 `~/Library/Application Support/im.yufei.manping/Secrets/`（`LocalSecretVault`），读取时不看签名。
- 签名仍影响防火墙软件（如 LuLu）的放行规则和系统的隐私授权。临时签名会随每次构建变化，固定证书可以避免重复放行。
- 本机安装使用自签名证书即可，不需要付费 Apple Developer、Developer ID 或公证。第一次换成新证书时，系统会要求重新授权一次。

## 一次设置固定签名

1. **Apple Development 证书**
   - 在 Xcode →「设置」→「Accounts」中选择 Apple ID 与团队，点「Manage Certificates…」，再点「+」→「Apple Development」。
   - 构建前设置环境变量：

     ```bash
     export MANPING_SIGN_IDENTITY="Apple Development: 你的名字 (团队ID)"
     ```

2. **自签名证书**
   - 打开「钥匙串访问」，依次选择「证书助理」→「创建证书…」。
   - 名称填 `Manping Yufei Signing`，身份类型选「自签名根证书」，证书类型选「代码签名」。
   - 创建后，构建脚本会自动识别并使用它，不需要设置环境变量。

## 正式发布签名

`dist/release` 下的发布包优先使用固定的自签名证书 `Manping Yufei Release Signing`。证书和私钥放在：

```text
~/Library/Application Support/Manping Yufei Signing/
```

该目录包含独立的 `signing.keychain-db` 和 `keychain-password`，不放在系统钥匙串搜索列表中。创建证书后用 `codesign -dvv` 记录实际证书指纹；按签名放行的软件应同时核对 `im.yufei.manping` 和这张新证书。

请备份整个签名目录。丢失后无法再签出同一个 App，使用者需要重新放行防火墙等规则。

## 签名选择顺序

`scripts/bundle.py` 依次选择：

1. `MANPING_SIGN_IDENTITY`，可配合 `MANPING_SIGN_KEYCHAIN` 指定钥匙串文件；
2. 上述正式发布签名钥匙串；
3. `Manping Yufei Signing`；
4. 都没有时使用临时签名。

`scripts/build_debug_app.py` 使用 1、3、4。首次使用证书时，`codesign` 可能请求使用私钥，请选择「始终允许」。

## 覆盖安装

先退出满屏，然后运行：

```bash
python3 scripts/install_local_app.py --dry-run
python3 scripts/install_local_app.py --replace
```

脚本校验 Bundle ID、可执行文件和签名，在同目录暂存并再次校验后替换 `/Applications/满屏.app`。旧应用会保留为同名隐藏备份；替换失败时自动恢复。应用正在运行或没有目录写权限时，脚本会停止，不会自动提权或终止进程。
