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
targets: TLingo, TLingoTranslation, TLingoBroadcastUpload, TLingoWidgets, ShareCore, ShareCoreTests, TLingoUITests, TLingo-Direct, TLingoHelper
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

## 文本翻译延迟 benchmark（仅 Debug iOS，显式启用）

在指定模拟器安装 Debug App 后，用 `simctl launch` 传入：

```bash
SIMCTL_CHILD_TLINGO_TEXT_BENCHMARK=1 \
SIMCTL_CHILD_TLINGO_TEXT_BENCHMARK_REPEATS=3 \
SIMCTL_CHILD_TLINGO_TEXT_BENCHMARK_OUTPUT=<app-data-container>/Documents/text-benchmark \
xcrun simctl launch --terminate-running-process <UDID> com.zanderwang.AITranslator
```

可用 `SIMCTL_CHILD_TLINGO_TEXT_BENCHMARK_MODELS=<comma-separated-IDs>` 限定模型。
benchmark 使用隔离的偏好、生产 `HomeViewModel`、鉴权、请求及结果卡片，英文译为简体中文；
短文本重复指定次数，长段落一次，模型串行执行。不会改变用户模型选择、默认模型或会员权限。
输出 `models.json`、`inputs.json`、逐条持久化的 `results.json` 和成功结束标记 `complete.txt`。
HTTP 成功不等于翻译质量正确；失败与不可用模型不纳入成功延迟统计。
`firstUIFrame` / `finalUIFrame` 是结果卡片更新后第二个 display callback 的近似值，
不是像素可见性或 Markdown 解析完成的精确证明；必须结合截图或录屏检查，
不可将后台/屏幕外的 UI 更新当作用户已经看到完整结果。

## 性能埋点

Instruments 的 Points of Interest 轨道（subsystem `com.zanderwang.AITranslator`）记录：

- `Translation Run`：每个模型结果从提交到 `resultApplied` 的区间；`Translation Stage` 事件标出
  `TranslationTimingTrace` 各阶段首次到达的毫秒数。未完成即被释放的区间以 `incomplete` 结束。
- `Realtime Translation`：每次实时翻译调用，附 provider。

App 启动时订阅 MetricKit，最近 20 个 metric/diagnostic payload 保存在 App 缓存目录的 `MetricKit/`；
反馈邮件附件和 macOS 导出日志附带最新 5 个，以 `[MetricKit]` 行输出。

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
