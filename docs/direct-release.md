---
status: current
owner: repository
verified_commit: f192a538690702badaed5bac19f103c9606f3d51
review_triggers:
  - Xcode Cloud workflow changes
  - Direct signing or notarization changes
  - Sparkle appcast changes
  - release storage changes
---

# Direct 发布流程

`TLingo-Direct` 由独立的 Xcode Cloud 工作流构建。App Store 工作流继续使用 `TLingo` scheme，两个流程不得共享发布动作。

## 云端工作流

Direct 工作流使用以下固定配置：

```text
name: Direct Release
project: ios/AITranslator.xcodeproj
scheme: TLingo-Direct
platform: macOS
configuration: Release
Xcode: 27
macOS: 26.6.2
trigger: v* tag
```

工作流的 Distribution Preparation 使用 `None`。Xcode Cloud archive 本身使用临时 ad-hoc 签名；`ci_post_xcodebuild.sh` 从 `CI_ARCHIVE_PATH` 使用专用 Developer ID 证书重新导出，再提交公证并 staple。不要选择 App Store 分发，也不要使用 Xcode 27 Beta 发布。

固定选择正式版 Xcode 27 和 macOS 26.6.2，不使用 `Latest Beta or Release`。当前 Xcode Cloud 不接受 Xcode 26.6 与 macOS 26.6.2 的组合。

关闭 tag 条件的自动取消。每个正式版本都必须完整执行，后续 tag 不得取消正在发布的版本。

## 脚本入口

Xcode Cloud 以 `ios/AITranslator.xcodeproj` 为容器，因此自动调用 `ios/ci_scripts/` 下的入口脚本。入口脚本再调用仓库根目录的共享实现：

- `ios/ci_scripts/ci_post_clone.sh` → `ci_scripts/ci_post_clone.sh`：生成 gitignored `AppSecrets.swift` 并配置 Swift package macro 信任。
- `ios/ci_scripts/ci_pre_xcodebuild.sh` → `ci_scripts/ci_pre_xcodebuild.sh`：仅为 `Direct Release` archive 校验 tag、版本、CHANGELOG 和 Sparkle 构建号，并把 Git commit count + 1000 写入 `CURRENT_PROJECT_VERSION`。offset 保证拆分出的新仓库构建号高于旧仓库最后发布的 780。
- `ios/ci_scripts/ci_post_xcodebuild.sh` → `ci_scripts/ci_post_xcodebuild.sh`：验证 Developer ID 签名、公证、版本和构建号，创建 DMG，生成 Sparkle appcast，并发布到 R2。

非 `Direct Release` 工作流会立即跳过 Direct 逻辑。没有 `v*` tag 的手动 Direct 构建只生成 archive，不发布文件。

## 环境变量

在 `Direct Release` 工作流中配置：

| Name | Secret | Purpose |
| --- | --- | --- |
| `SPARKLE_PRIVATE_KEY` | Yes | Sign the DMG for Sparkle |
| `CLOUDFLARE_API_TOKEN` | Yes | Upload and read back R2 objects |
| `DEV_ID_CERT_P12` | Yes | Base64-encoded Developer ID Application identity |
| `DEV_ID_CERT_PASSWORD` | Yes | Password protecting the Developer ID PKCS#12 file |
| `KEYCHAIN_PASSWORD` | Yes | Password for the ephemeral build keychain |
| `ASC_API_KEY_ID` | Yes | App Store Connect API key ID for notarization |
| `ASC_API_ISSUER_ID` | Yes | App Store Connect API issuer ID for notarization |
| `ASC_API_KEY_P8_B64` | Yes | Base64-encoded App Store Connect API private key for notarization |
| `TLINGO_CLOUD_ENDPOINT` | Yes | Cloud Worker endpoint written into `AppSecrets.swift` |
| `TLINGO_CLOUD_SECRET` | Yes | Cloud HMAC signing secret written into `AppSecrets.swift` |
| `TLINGO_SUPABASE_URL` | Yes | Supabase URL written into `AppSecrets.swift` |
| `TLINGO_SUPABASE_ANON_KEY` | Yes | Supabase anon key written into `AppSecrets.swift` |
| `CLOUDFLARE_ACCOUNT_ID` | No | Required Cloudflare account ID; GitHub Actions reads it from `vars.CLOUDFLARE_ACCOUNT_ID` |
| `DIRECT_RELEASE_WORKFLOW_NAME` | No | Optional override; defaults to `Direct Release` |
| `DIRECT_RELEASE_R2_BUCKET` | No | Optional override; defaults to `tlingo-releases` |
| `APPCAST_BASE_URL` | No | Optional override; defaults to `https://updates.tlingo.zanderwang.com` |

不要把这些值写入仓库、日志或构建产物。

仓库迁移不会自动把 GitHub Actions variables 或其他工作流的 shared environment variables 注入 `Direct Release`。必须在 Direct 工作流中单独配置上述变量，或明确关联产品级共享变量。

## 发布顺序

正式 `vX.Y.Z` tag 的发布顺序固定为：

1. 验证 `MARKETING_VERSION`、CHANGELOG 和 tag 一致。
2. 验证新 build number 严格大于线上 appcast。
3. 验证 `codesign`、stapler 和 Gatekeeper assessment。
4. 创建 `TLingo-vX.Y.Z.dmg` 并生成 release notes 与 appcast。
5. 先上传版本化 DMG。
6. 再上传版本化 release notes。
7. 最后上传 `appcast.xml`，使它成为发布提交点。
8. 从 R2 重新下载三个对象并逐字节比较。

任何步骤失败都不得更新 appcast。

## 迁移和回退

Xcode Cloud 迁移已由 Build 459 的 `v3.7.9` 正式发布验证。`.github/workflows/release-direct.yml` 只保留 `workflow_dispatch` 触发（在 tag ref 上手动运行），作为回退实现；不得让 GitHub Actions 和 Xcode Cloud 同时响应正式 `v*` tag。

发生云端发布故障时，可以先停用 Xcode Cloud，再手动启用保留的 GitHub workflow。任何时候不得让两个系统并发写入同一个 appcast。

Xcode Cloud `Direct Release` 只匹配以 `v` 开头的 tag，不监听 branch push，并关闭 tag build 的自动取消。

## 验证

仓库内静态验证：

```bash
bash -n ci_scripts/ci_post_clone.sh \
  ci_scripts/ci_pre_xcodebuild.sh \
  ci_scripts/ci_post_xcodebuild.sh \
  ci_scripts/validate-direct-release.sh \
  ci_scripts/generate-appcast.sh \
  ci_scripts/extract-release-notes.sh \
  ios/ci_scripts/ci_post_clone.sh \
  ios/ci_scripts/ci_pre_xcodebuild.sh \
  ios/ci_scripts/ci_post_xcodebuild.sh

ci_scripts/validate-direct-release.sh X.Y.Z
```

云端完成后必须检查：

- Xcode Cloud archive 成功且使用 `TLingo-Direct`。
- DMG 中的 app 通过 Developer ID、stapler 和 Gatekeeper 验证。
- `CFBundleShortVersionString` 等于 tag 版本。
- `CFBundleVersion` 大于旧 appcast build number。
- R2 中的 DMG、release notes 和 appcast 与本次生成文件一致。
- 一台安装旧 Direct 版本的 Mac 可以通过 Sparkle 发现并安装更新。

## 已验证基线

`v3.7.9` / Xcode Cloud Build 459 已验证：

- Developer ID export、notarization、stapler 和 Gatekeeper assessment 通过。
- Headless DMG 包含 `TLingo.app` 和 Applications 链接。
- Sparkle appcast 为 `3.7.9` / build `759`。
- DMG、release notes 和 appcast 依次上传后从 R2 读回并逐字节比较通过。
- 公开 DMG 下载后的签名、公证、版本、构建号和最低系统版本复核通过。
