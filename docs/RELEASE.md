# 版本与发布

分发方式：Developer ID 签名 + 公证，直接分发（不上 App Store），Sparkle 2 应用内自动更新，安装包放在 GitHub Release。
**在本机发版**（不用 CI）：一条命令完成门禁、版本号、提交、tag、签名、公证、Sparkle 签名和上传，思路与 Span 的 `release.sh` 一键发布一致。

## 版本号规则

- 格式 `主.次.修订`，当前是 **0.1.x**。
- **每次发版只把最后一位加 1**：0.1.1 → 0.1.2 → 0.1.3 → …，没有上限（0.1.10、0.1.99 都可以）。
- 次版本号、主版本号（0.2.0、1.0.0）**只在用户明确说"这个版本 OK 了"时才升**，用 `scripts/bump_version.sh 0.2.0` 显式指定。其他任何情况都不改前两位。
- 构建号 `CFBundleVersion` 等于版本号（`CURRENT_PROJECT_VERSION: "$(MARKETING_VERSION)"`）。Sparkle 用它判断新旧，所以版本号必须单调递增，发出去的版本号不能再用。
- 0.1.1 是基线：完整跑通 MTP 文件管理的全部基本能力（见 CHANGELOG）。之后的版本在它的基础上修复和优化，计划见 [ROADMAP.md](ROADMAP.md)。

## 什么时候发版

- **每个功能、每个修复都单独提交**（提交信息写清楚做了什么），并在 CHANGELOG 的「## 未发布」里加一条用户能看懂的说明。
- **但不是每一项都发版**：多项改动攒成一批，再切一个修订版，避免版本太频繁。一批做到哪里收尾，由用户决定；Claude 在一批工作告一段落时询问是否发版。
- 线上版本有影响使用的 bug 时例外：修好就单独发一个修订版。
- 发版前的门禁（`bump_version.sh` 自动跑前两项）：
  - PierKit 单元测试全部通过；
  - Release 构建成功，并且**零编译警告**；
  - 这一批改动涉及的功能**在真实设备上验证过**（DBI 或 Android 手机；写入只在测试目录里，测完删掉）。没法实机验证的，在 CHANGELOG 里注明。
- 升次版本号、主版本号必须先问用户。

## 发版步骤

```bash
scripts/bump_version.sh --push
```

依次执行：
1. `bump_version.sh`：检查工作区干净且在 main → 跑门禁 → 版本号最后一位 +1 → 把 CHANGELOG 的「未发布」改成 `## 0.1.N — 日期` → 提交 `release: 0.1.N` → 打 tag `v0.1.N` → 推送 main 和 tag；
2. `publish.sh`：`release.sh`（archive → Developer ID 导出 → 签名/版本自检 → 公证 → staple → `Pier-<版本>.zip`）→ 从钥匙串导出 Sparkle 私钥到临时文件 → `make_appcast.sh` 签名并生成 `appcast.xml` → 删掉临时私钥 → `gh release create`（说明取自 CHANGELOG 的这一节）。

不加 `--push` 就只在本地提交和打 tag，确认无误后再手动执行它最后打印的那条命令。
公证等步骤失败时，修好原因后单独重跑 `scripts/publish.sh` 即可（它会检查当前提交就是这个 tag，GitHub 上还没有这个 Release）。
`SKIP_NOTARIZE=1 scripts/release.sh` 可以只检查构建和签名、不公证，这样的包不能发布。

已安装的 Pier 每天自动检查一次 `releases/latest/download/appcast.xml`（永远指向最新的 Release，不用维护历史条目），也可以从 App 菜单 ▸ 检查更新… 手动检查。

## 出了问题

- Sparkle 不支持降级：发出去有问题的版本，**往前修**，发下一个修订版。
- 如果一个版本严重到不能留在线上：先把那个 GitHub Release 删掉（`latest` 会回到上一个版本，还没更新的用户不会再收到它），再尽快发修复版。
- `publish.sh` 失败（证书、公证、网络）：修好后重跑 `scripts/publish.sh`，不需要重新切版本。

## 一次性设置（都在这台 Mac 上）

1. **GitHub 仓库** `lixiaolin94/Pier`（公开，已建好）。必须能匿名下载 Release 资源，因为 Sparkle 下载更新不带登录凭据。`gh` 要已登录。
2. **Developer ID Application 证书**：已在登录钥匙串里（Xcode 装的）。证书 2027-02 到期，到期后在 Xcode ▸ Settings ▸ Accounts 里重建。
3. **Sparkle EdDSA 私钥**：已在登录钥匙串里，Pier 与 Inbox 共用一把（Sparkle 官方建议一个开发者用一把）；公钥写在 `project.yml` 的 `SUPublicEDKey` 中。私钥丢了，老用户就没法自动升级，备份在密码 App 里。
4. **公证凭据**（只需执行一次，需要 Apple ID 和一个 App 专用密码，在 account.apple.com ▸ 登录与安全 ▸ App 专用密码里生成）：
   ```bash
   xcrun notarytool store-credentials inbox-notary --apple-id <Apple ID> --team-id YWQ4TY4VR5
   ```
   这是账号级凭据，Inbox 的本地发版也用这个名字。
5. **第一次安装要手动装**：0.1.1 是第一个带 Sparkle 的版本，要从 GitHub Release 下载后拖进「应用程序」。之后全部走应用内更新。
