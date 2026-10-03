# 版本与发布

分发方式：Developer ID 签名 + 公证，直接分发（不上 App Store），Sparkle 2 应用内自动更新。
构建、签名、公证、发布全部由 GitHub Actions 完成（`.github/workflows/release.yml`），
流程与 Inbox 相同，思路与 Span 的 `release.sh` 一键发布一致。

## 版本号规则

- 格式 `主.次.修订`，当前是 **0.1.x**。
- **每次发版只把最后一位加 1**：0.1.1 → 0.1.2 → 0.1.3 → …，没有上限（0.1.10、0.1.99 都可以）。
- 次版本号、主版本号（0.2.0、1.0.0）**只在用户明确说"这个版本 OK 了"时才升**，用 `scripts/bump_version.sh 0.2.0` 显式指定。其他任何情况都不改前两位。
- 构建号 `CFBundleVersion` 等于版本号（`CURRENT_PROJECT_VERSION: "$(MARKETING_VERSION)"`）。Sparkle 用它判断新旧，所以版本号必须单调递增，发出去的版本号不能再用。
- 0.1.1 是基线：完整跑通 MTP 文件管理的全部基本能力（见 CHANGELOG）。之后的版本在它的基础上修复和优化，计划见 [ROADMAP.md](ROADMAP.md)。

## 什么时候发版（自动发版规则）

满足下面全部条件就可以发，不用等凑够大功能：

1. **一批完整的改动**：ROADMAP 里一项做完，或者一个 bug 修完。半成品不发；一个版本只解决一件事或一组紧密相关的事。
2. **CHANGELOG 写好**：在「## 未发布」下面用用户能看懂的话写清楚改了什么（脚本会检查不为空）。
3. **门禁全过**（`bump_version.sh` 自动跑前两项）：
   - PierKit 单元测试全部通过；
   - Release 构建成功，并且**零编译警告**；
   - 改动涉及的功能**在真实设备上验证过**（DBI 或 Android 手机；写入只在测试目录里，测完删掉）。没法实机验证的，在 CHANGELOG 里注明"未实机验证"。
4. 线上版本有影响使用的 bug 时，**修好立即发一个修订版**（同样过门禁），不和其他改动混在一起。

Claude 在完成 ROADMAP 里的一项、满足以上条件后，可以直接发版（`scripts/bump_version.sh --push`），然后告诉用户版本号和改动。升次版本号、主版本号必须先问用户。

## 发版步骤

```bash
scripts/bump_version.sh --push
```

脚本依次：检查工作区干净且在 main → 跑门禁 → 版本号最后一位 +1 → 把 CHANGELOG 的「未发布」改成 `## 0.1.N — 日期` → 提交 `release: 0.1.N` → 打 tag `v0.1.N` → 推送 main 和 tag。
不加 `--push` 就只在本地提交和打 tag，确认无误后再手动推送。

推送 tag 后 CI 自动完成：校验 tag 与版本号一致 → 单元测试 → archive → Developer ID 签名导出 → 签名/版本自检 → 公证 → staple → `Pier-<版本>.zip` → Sparkle EdDSA 签名 → `appcast.xml` → GitHub Release（说明取自 CHANGELOG 的这一节）。

已安装的 Pier 每天自动检查一次 `releases/latest/download/appcast.xml`（永远指向最新的 Release，不用维护历史条目），也可以从 App 菜单 ▸ 检查更新… 手动检查。

## 出了问题

- Sparkle 不支持降级：发出去有问题的版本，**往前修**，发下一个修订版。
- 如果一个版本严重到不能留在线上：先把那个 GitHub Release 删掉（`latest` 会回到上一个版本，还没更新的用户不会再收到它），再尽快发修复版。
- CI 失败（证书、公证等）：修好后删掉远端 tag 重新推送，或者用下面的本地备用路径。

## 一次性设置

1. **GitHub 仓库** `lixiaolin94/Pier`。必须是公开仓库，或者至少 Release 资源可以匿名下载，因为 Sparkle 下载更新不带登录凭据。
2. **仓库 secrets**（与 Inbox 相同的值）：
   - `SPARKLE_ED_PRIVATE_KEY`：Sparkle EdDSA 私钥。Pier 与 Inbox 共用一把（Sparkle 官方建议一个开发者用一把），私钥在登录钥匙串里，公钥已经写在 `project.yml` 的 `SUPublicEDKey` 中。导出：
     ```bash
     build/sparkle-tools/bin/generate_keys -x /tmp/sparkle_ed_key && gh secret set SPARKLE_ED_PRIVATE_KEY -R lixiaolin94/Pier < /tmp/sparkle_ed_key && rm /tmp/sparkle_ed_key
     ```
   - `MAC_CERT_P12` / `MAC_CERT_PASSWORD`：经典 Developer ID Application 证书（.p12 的 base64 和密码）。证书 2027-02 到期，到期后要重建证书、重新导出 .p12、更新这两个 secret（Inbox 也要同步更新）。
   - `ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_KEY_P8`：App Store Connect API key（Admin），用于公证。
3. **第一次安装要手动装**：0.1.1 是第一个带 Sparkle 的版本，要从 GitHub Release 下载后拖进「应用程序」。之后全部走应用内更新。

## 本地备用路径

CI 不可用时（需要登录钥匙串里有 Developer ID 证书，以及 notarytool 的钥匙串 profile `inbox-notary`）：

```bash
scripts/release.sh
build/sparkle-tools/bin/generate_keys -x /tmp/sparkle_ed_key
SPARKLE_ED_PRIVATE_KEY="$(cat /tmp/sparkle_ed_key)" scripts/make_appcast.sh && rm /tmp/sparkle_ed_key
gh release create v<版本> build/release/Pier-*.zip build/release/appcast.xml --notes-file <说明>
```
