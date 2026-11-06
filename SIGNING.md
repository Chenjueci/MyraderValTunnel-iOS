# 签名版 CI：让 packet-tunnel 扩展真正被系统激活

`build-ipa.yml`（免签名）产出的 IPA 能被 TrollStore 等工具装上，但
**`packet-tunnel` 属于受限授权**：网络扩展通常需要一份带
`com.apple.developer.networking.networkextension = [packet-tunnel]`
能力的 provisioning profile 背书，系统才会允许扩展运行。若你发现
「App 装得上、点连接后 VPN 不建立 / 扩展报错」，就用本文件对应的
**`build-ipa-signed.yml`** 出一份已签名的 IPA。

> 全程仍在 GitHub 云端 macOS Runner 上完成，**你不需要 Mac**。
> 但需要一个 **Apple 开发者账号**（免费个人账号即可用于 development 调试）。

---

## 第 1 步：准备证书（.p12）

1. 在 Mac 的「钥匙串访问」中，把你的 **Apple Development** 证书
   （含私钥）导出为 `cert.p12`，设置一个导出密码。
   > 没有 Mac 也可在 [Apple Developer](https://developer.apple.com/account/resources/certificates)
   > 用 CSR 创建证书，但导出 p12 需要钥匙串；可用任意一台 Mac 或 CI 一次性生成。
2. 转 base64：
   ```bash
   base64 -i cert.p12 | pbcopy      # macOS
   # Linux: base64 -w0 cert.p12
   ```

## 第 2 步：准备两份 provisioning profile

因为工程有两个 Bundle ID，**必须各配一份** profile，且都要启用
**Network Extensions（Packet Tunnel）** 能力：

| # | Bundle ID | 用途 |
| --- | --- | --- |
| 1 | `com.myraderval.MyraderValTunnel` | 容器 App |
| 2 | `com.myraderval.MyraderValTunnel.extension` | 网络扩展 |

在 [Profiles](https://developer.apple.com/account/resources/profiles/list) 里：

1. 先注册两个 App ID（Identifiers），**两个都勾选 Network Extensions**；
   packet-tunnel 是受限能力，个人账号通常可勾选用于开发。
2. 注册测试设备的 **UDID**（development / ad-hoc profile 必需）。
3. 分别创建两份 profile（类型选 iOS App Development 或 Ad Hoc），
   选对应 App ID + 你的证书 + 测试设备，下载得到 `.mobileprovision`。
4. 各自转 base64：
   ```bash
   base64 -i app.mobileprovision | pbcopy
   base64 -i ext.mobileprovision | pbcopy
   ```

> Bundle ID 如果要改，需同步修改 `project.yml` 的两个
> `PRODUCT_BUNDLE_IDENTIFIER`、`ContentView.swift` 的
> `extensionBundleId`、`build-ipa-signed.yml` 里
> `ExportOptions.plist` 的 `provisioningProfiles` 键名。

## 第 3 步：配置 GitHub Secrets

仓库 → **Settings → Secrets and variables → Actions → New repository secret**，添加：

| Secret | 内容 |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | `cert.p12` 的 base64（单行，无换行） |
| `P12_PASSWORD` | 导出 p12 时设的密码 |
| `KEYCHAIN_PASSWORD` | 任意随机字符串，仅用于 CI 临时钥匙串 |
| `APP_PROVISION_PROFILE_BASE64` | 容器 App 的 `.mobileprovision` base64 |
| `EXT_PROVISION_PROFILE_BASE64` | 扩展的 `.mobileprovision` base64 |
| `TEAM_ID` | 开发者账号的 Team ID（10 位，如 `A1B2C3D4E5`） |

工作流会自动：解析 profile 的 `UUID` 与 `Name` → 安装到
`~/Library/MobileDevice/Provisioning Profiles/` → 生成
`Signing.xcconfig`（`APP_PROFILE` / `EXT_PROFILE` 分别对应两个 target 的
`PROVISIONING_PROFILE_SPECIFIER`）→ archive → 用
`ExportOptions.plist` 按 Bundle ID 映射重签导出。

## 第 4 步：触发与安装

1. 仓库 **Actions → Build iOS IPA (signed, no Mac needed) → Run workflow**；
   `export_method` 选 `development`（默认）或 `ad-hoc`。
2. 构建完成后下载 Artifact `MyraderValTunnel-signed.ipa`。
3. 安装方式（任选）：
   - **Apple Configurator 2 / Xcode Devices** 拖入真机；
   - **Sideloadly / AltStore**：选该 IPA，用你的 Apple ID 安装（此时 IPA 已签名，不要重复重签）；
   - `ios-deploy`、iMazing 等任意支持已签名 IPA 的工具。
4. 首次打开需在本机
   `设置 → 通用 → VPN 与设备管理` 里信任开发者证书。

---

## 常见问题

| 现象 | 原因 / 处理 |
| --- | --- |
| `No provisioning profile matches ...` | profile 的 App ID 与 Bundle ID 不一致，或没勾 Network Extensions，回去重做第 2 步 |
| `Code Signing Error: ... requires a provisioning profile` | Secrets 没填全 / base64 被截断（确保单行无换行） |
| archive 成功但导出失败 | `ExportOptions.plist` 的 `method` 与 profile 类型不匹配（Ad Hoc profile 选 `ad-hoc`） |
| 装上了、VPN 仍不建立 | 确认两份 profile 都带 `packet-tunnel` entitlement；用 `codesign -d --entitlements :- Payload/.../MyraderValTunnel.appex` 检查 |
| 想分发给非注册设备 | 需企业（in-house）账号或 App Store + Network Extensions 授权，个人账号做不到 |

---

## 与免签名版怎么选

| 场景 | 用哪个工作流 |
| --- | --- |
| 有 TrollStore（可保留任意 entitlements） | `build-ipa.yml` 免签名版即可，最简单 |
| 普通侧载 / 需要系统真正激活 VPN 扩展 | `build-ipa-signed.yml` 签名版 |
| 有 Mac 且想本地调试 | 直接 `xcodegen generate` + Xcode 自动签名，不必走 CI |
