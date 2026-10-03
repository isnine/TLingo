---
status: current
owner: repository
verified_commit: initial
review_triggers:
  - test command changes
  - scheme or target changes
  - CI changes
---

# 验证矩阵

## 通用

```bash
git diff --check
jq empty ios/Localizable.xcstrings
```

Swift 文件使用 scoped lint：

```bash
swiftformat --lint <touched-files>
swiftlint lint <touched-files>
```

首次构建前运行 `./ci_scripts/generate-app-secrets.sh` 生成 `AppSecrets.swift`。
Xcode Cloud 会在 post-clone 和 pre-xcodebuild 阶段重新生成该文件；正式工作流缺少所需的
`TLINGO_*` 环境变量时必须直接失败，不得使用 `example.invalid` 占位配置继续归档。迁移期间脚本兼容
已有的 `AITRANSLATOR_CLOUD_*` 和 `SUPABASE_*` 名称；新配置统一使用 `TLINGO_*`。

## Apple

```text
project: ios/AITranslator.xcodeproj
targets: TLingo, TLingoTranslation, TLingoBroadcastUpload, ShareCore, ShareCoreTests, TLingoUITests, TLingo-Direct, TLingoHelper
schemes: ShareCore, TLingo, TLingo-Direct, TLingoHelper, TLingoBroadcastUpload, TLingoTranslation, TLingoUITests
```

| Change | Required gate |
| --- | --- |
| Shared Swift logic | Targeted `ShareCoreTests` + relevant platform build |
| iOS UI / TranslationUI / ReplayKit | `TLingo` iOS Simulator build |
| macOS UI | `TLingo` macOS build |
| macOS MLX / MOSS | `TLingo` macOS build with `-skipPackagePluginValidation` |
| Direct-only | `TLingo-Direct` macOS build |
| Helper / cross-app selection boundary | `TLingoHelper` and `TLingo-Direct` macOS builds + sandboxed `TLingo` Release build + real-Mac selection/focus checks |
| Cross-platform shared UI | iOS Simulator and macOS builds |
| Realtime lifecycle | Targeted tests plus real/synthetic producer drain scenario |

Helper protocol changes also require `TextPopupRequestTests` and `DeepLinkTests`.
Verify cold launch, menu-bar-only operation, multi-screen positioning, Escape,
permission denial/revocation, absent/incompatible TLingo, encoded URL length limits,
and the absence of a Replace action. The Helper never updates or installs TLingo.

完整逻辑测试：

```bash
xcodebuild -project ios/AITranslator.xcodeproj -scheme TLingo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:ShareCoreTests test
```

设置排序的交互与重启持久化使用独立 UI 测试 scheme；`TLingo` scheme 不包含 `TLingoUITests`：

```bash
xcodebuild -project ios/AITranslator.xcodeproj -scheme TLingoUITests \
  -destination 'platform=iOS Simulator,id=<UDID>' \
  -only-testing:TLingoUITests/ModelResultOrderUITests test
```

## 文档

- Markdown 相对链接必须解析到 tracked 文件。
- 命令中引用的 scheme 和 script 必须实际存在。

## Direct release CI

```bash
bash -n ci_scripts/ci_post_clone.sh \
  ci_scripts/ci_pre_xcodebuild.sh \
  ci_scripts/ci_post_xcodebuild.sh \
  ci_scripts/validate-direct-release.sh \
  ci_scripts/generate-appcast.sh \
  ci_scripts/extract-release-notes.sh \
  ci_scripts/generate-app-secrets.sh \
  ios/ci_scripts/ci_post_clone.sh \
  ios/ci_scripts/ci_pre_xcodebuild.sh \
  ios/ci_scripts/ci_post_xcodebuild.sh
```

正式发布还必须通过 [`direct-release.md`](./direct-release.md) 中的签名、公证、R2 读回和 Sparkle 升级验证。
