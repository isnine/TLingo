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

## Apple

```text
project: ios/AITranslator.xcodeproj
targets: TLingo, TLingoTranslation, TLingoBroadcastUpload, ShareCore, ShareCoreTests, TLingoUITests, TLingo-Direct
schemes: ShareCore, TLingo, TLingo-Direct, TLingoBroadcastUpload, TLingoTranslation, TLingoUITests
```

| Change | Required gate |
| --- | --- |
| Shared Swift logic | Targeted `ShareCoreTests` + relevant platform build |
| iOS UI / TranslationUI / ReplayKit | `TLingo` iOS Simulator build |
| macOS UI | `TLingo` macOS build |
| macOS MLX / MOSS | `TLingo` macOS build with `-skipPackagePluginValidation` |
| Direct-only | `TLingo-Direct` macOS build |
| Cross-platform shared UI | iOS Simulator and macOS builds |
| Realtime lifecycle | Targeted tests plus real/synthetic producer drain scenario |

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
