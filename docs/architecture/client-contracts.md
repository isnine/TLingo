---
status: current
owner: architecture
verified_commit: initial
review_triggers:
  - Swift endpoint changes
  - HMAC or entitlement changes
---

# 客户端契约

云端 Worker 不在本仓库。本文只记录客户端依赖的外部契约；改变签名形状或 wire format 需要兼容已发布的客户端。

## Host 与路径

- `AppSecrets.cloudEndpoint` 指向 API host（生产为 `https://tlingo.zanderwang.com/api`）。
- 客户端请求 `/api/<internal-path>`，签名使用不含 `/api` 的 internal path。

## HMAC

```text
message = "<unix-seconds>:<internal-path>"
signature = HMAC-SHA256(AppSecrets.cloudSecret, message)
headers = X-Timestamp, X-Signature
```

签名不覆盖 method 或 body。HMAC 只用于 Native API compatibility，不代表用户身份或 entitlement。

| Internal path | Auth |
| --- | --- |
| `/models` | Public |
| `/{model}/chat/completions` | HMAC，会员模型另需 entitlement |
| `/translate/microsoft` | HMAC |
| `/tts`、`/marketplace/actions*` | HMAC |

模型 ID 含 `/` 时作为多级路径请求（如 `/api/qwen/qwen3.7-flash/chat/completions`），HMAC 对完整路径签名。

## 模型目录

`/models` 返回的 `tags` 是有序字符串数组。可选 `tagStyles` 按标签文字匹配，每项可提供 `textColor` 和 `backgroundColor`（`#RRGGBB`）；缺省或无法解析时使用默认颜色。

`gemini-4-hydrogen`、`gemini-4-argon`、`gemini-3.8-flash` 和 `gemini-4-carbon` 限时免费，带 `Limited Time Free` 标签；不改变免费默认模型或用户已保存的选择。
会员目录包含 `deepseek-v4-pro`（DeepSeek-V4-Pro），其 `isPremium: true`、`supportsVision: false`；
沿用聊天请求及结构化输出契约，不支持图片输入。`deepseek-flash` 继续保留且支持图片。
目录包含 `gemini-4-carbon`（Gemini 4 Carbon）和 `gemini-4-hydrogen`（Gemini 4 Hydrogen），其 `isPremium: false`、`supportsVision: true`；
沿用聊天、流式及 JSON Schema 输出契约。Argon、Carbon 和 Hydrogen 固定思考级别 `low`，不能保证零思考 token。
免费目录为 `gemini-4-hydrogen`、`gemini-4-argon`、`gemini-3.8-flash`、`gemini-4-carbon`（均限时）和默认模型 `gpt-5-mini`；完整目录顺序为 `gemini-4-hydrogen`、`gemini-4-argon`、`gemini-3.8-flash`、
`gpt-5-mini`、`gemini-4-carbon`、`gpt-5.6`、`deepseek-flash`、`deepseek-v4-pro`、`qwen/qwen3.7-flash`。
`gpt-oss-120b`、`z-ai/glm-5.3-flash`、`gemini-3.1-pro-preview` 从目录移除；不改模型路由及
会员校验，目录刷新前的已保存选择仍可请求，但这些旧选择不保证关闭思考。
`deepseek-flash` 展示为 `DeepSeek-V4.1-Flash-1017` 并带 `LATEST`。

思考策略由服务端强制执行，覆盖旧客户端的推理参数，普通请求和流式请求使用相同策略：
GPT-5 Mini 使用 `reasoning_effort: none`；Qwen 使用 `reasoning.enabled: false`；
DeepSeek Flash／Pro 使用 `thinking.type: disabled`；GPT-5.6 使用 `reasoning.effort: none`；
Gemini 3.8 Flash 使用零思考预算。Argon、Carbon 和 Hydrogen 固定 `low`。不改变 JSON Schema 输出契约、HMAC
或客户端的增量解析流程；无需客户端更新即可由新服务端覆盖已有请求设置。

## 文本流式计时

聊天请求发送随机 UUID `X-Request-ID`，仅用于关联诊断，不包含输入、身份或设备标识，也不改变 HMAC。
聊天请求还发送 `X-TLingo-Action`：内置动作为其 ID，自定义动作固定为 `custom`，仅用于服务端延迟分析，不改变 HMAC。
支持新埋点的 Worker 回显该 header，并返回
`Server-Timing: preupstream;dur=<ms>, upstream;dur=<ms>`；旧服务端只返回 `upstream` 仍兼容。
`X-Upstream-TTFB` 表示上游响应 header 等待时间，不代表首个内容 token。
末个内容、`[DONE]` 与传输 EOF 只能在流中或结束日志里测量，不能事后补写已发出的响应 header。

聊天请求附带 `X-Usage-Subject-Type/ID/Label` 标识请求主体，按优先级为：
App Store 会员（`appAccountToken`）、设备（`device`）。设备标识是首次使用时生成的随机 UUID，存于 Keychain
（`ThisDeviceOnly`，不随 iCloud 同步），不来自硬件或广告标识符。Worker 仅将其用于 AI Gateway 日志归属。

共享网络会话的请求使用 `User-Agent: TLingo/<版本> (<构建号>; <平台> <系统版本>; <设备型号>; <渠道>)`，
例如 `TLingo/3.8.4 (504; iOS 26.1; iPhone17,3; AppStore)`；渠道为 `AppStore`、`TestFlight` 或 `Debug`。
它只用于日志归属，不参与鉴权。

会员请求附带 `X-AppStore-Transaction`：当前有效会员交易的 StoreKit 2 JWS（`jwsRepresentation`），
由服务端校验；TestFlight 沙盒购买同样有效，这是会员模型的唯一凭证。客户端不再提供
TestFlight 本地开通会员的入口，TestFlight 双击版本号只切换开发者模式；Debug 构建保留本地会员开关。

新手试用先以 `POST /onboarding/trial` 提交 `{deviceID, deviceToken}`（设备 UUID 与 DeviceCheck token），
成功后试用请求携带 `X-Onboarding-Device: <deviceID>`。服务端按设备计数，超额返回 403
`{"error":"trial_exhausted"}`，客户端显示“试用次数已用完”提示；设备不支持 DeviceCheck 或服务不可用时显示试用暂不可用。

客户端使用单调时钟，分别记录提交后请求准备、响应 header、首个/末个非空内容 delta、
首个可展示的解析结果、首个 UI 更新和最终结果应用。JSON 前缀、reasoning、usage、空 delta
不能当作用户已经看到翻译。内容 delta 是流式事件片段，不等于 tokenizer token。
header 等待减上游 header 等待仅是包含 Worker 前置开销的估计，不得用完整生成耗时推算网络延迟。
非流式返回一次显示完整内容，不模拟逐字播放。

## 微软翻译

`POST /api/translate/microsoft` 接收 `{text, sourceCode?, targetCode}`，省略源语言时自动检测，返回 `{text}`。文本上限 50000 UTF-16 code units。

## 客户端行为约定

- 源语言“自动检测”在完整支持范围内识别；目标语言“自动选择”的偏好列表只用于选目标，不限制源语言候选。中文文本有明确简繁字形时优先依据文本，只有字形无法区分时才参考系统语言偏好。
- 源语言处于自动检测且已识别出具体语言时，语言名称前显示“检测”标签，沿用目标语言“自动”标签的样式；手动指定源语言时不显示该标签。
- 自动检测的语言选择器优先展示可信候选；选择候选仅影响当前文本，不更改保存的源语言偏好。中英混排且存在候选目标时可快捷切换当前文本的目标语言，清空输入后恢复偏好。
- Apple 翻译的中文繁简互转使用 Foundation 本地字形转换，语言对视为本地可用，无需语言包或 TranslationSession；结果标注为本地繁简转换，支持逐句对照。该路径不承诺地区用语本地化，也不切换云端供应商；其他语言对保持系统翻译路径。
- 文本输入框中单独按 Tab 交换源语言和目标语言，不提交翻译；输入法组合文字或带修饰键时不拦截。
- 结果排序偏好保存在 App Group UserDefaults（`model_result_order`），不通过 iCloud 同步；默认按首次出现结果的时间升序（`firstCompletedFirst`，出结果后位置固定，不随完成或失败跳动），可选按模型列表顺序（`modelList`）。
- 首次安装且未保存模型选择时，默认启用微软翻译和 AI 模型目录中的第一个免费模型（目录顺序），不启用付费模型。
- 免费用户点击另一个免费云端 AI 模型时，直接替换当前免费云端模型，不要求先取消旧选择；其他翻译服务、Apple Intelligence、自定义端点及已保存的锁定付费选择保持不变。会员仍可多选，取消最后一个模型时仍保留可用默认模型。


## AirFeedback: anonymous feedback and automatic crash diagnostics

Only the main `ios/AITranslator` app integrates AirFeedback. No Helper, widget,
extension, ShareCore, account/authentication, translation API, release pipeline,
service setting, policy website, or App Store Connect privacy label is changed.
`FeedbackMail` and the existing local `MetricKitReporter` remain separate and
unchanged. Settings **Feedback** opens the anonymous form; **Email Support** keeps
the existing mail workflow, including its existing user-visible diagnostics behavior.
The onboarding mail entry is unchanged.

### Public configuration and verification

`Feedback/AirFeedbackConfiguration.swift` contains only the public ingest `key`,
`feedbackEndpoint`, `crashEndpoint`, and expected `bundleId` read from production
`workers app-key`, plus Apple team `JW2LR94V6G`. The bundle is
`com.zanderwang.AITranslator`. This is a shipped, public **ingestion-only** key,
not a management credential, account token, identity, translation secret, or
HMAC secret. Requests use `Authorization: Bearer <public ingest key>` and
`Content-Type: application/json`, independently of TLingo's translation client.

The unchanged official `AirDeviceProof.swift` optionally signs the exact JSON
bytes. It obtains a challenge at the ingest sibling `attestation/challenge`,
then submits `{scheme: "app-attest", keyId, attestation, challenge, appId}` at
`attestation`; `appId` is the Apple team and bundle joined by `.`. A report's
optional proof headers are `X-Attest-Key-Id` and `X-Attest-Assertion`.
`X-Attest-Status: unknown-key` resets the proof key for the next submission.
The proof key ID and refused build are stored in standard UserDefaults; no
account is involved. Both manual feedback and crashes can carry this proof;
it is not a user/account or analytics identifier.

Only the main app has App Attest entitlements: Debug `development`, Release
`production`. Compatible App Store/TestFlight builds and correctly provisioned
App IDs are needed for verified reports. Simulator, unsupported devices,
Developer ID Macs, local development builds, unavailable attestation, or a
failed proof still submit successfully as **unverified**. Verification is never
a submission requirement. Signing/profile capability and verified production
device behavior have not been established by static source checks. The upstream
proof asset is unchanged, including its first-use attestation concurrency behavior.

### Optional, manually submitted feedback

Nothing is submitted merely by opening the form. Send requires nonblank text or
at least one user-selected image. The exact JSON fields are:

- `message`: only the user's draft; maximum 4000, conservatively bounded in UTF-16
  units without splitting a user-perceived character, in both the form and client.
- `appVersion`, `appBuild`: main bundle version/build strings.
- `deviceModel`: hardware model (`uname` on iOS, `hw.model` on macOS), not a unique
  device identifier.
- `osVersion`: system name/version on iOS; macOS operating-system version string.
- `locale`: `Locale.current.identifier`.
- `images`: zero to four `{mediaType: "image/jpeg", data: <base64 JPEG>}` objects,
  selected by the user via PhotosPicker (iOS) or the file importer (macOS).
  Images are rendered/re-encoded to JPEG with longest side at most 2048 pixels;
  macOS also checks each encoded image against the server's 8 MiB limit.

No local logs, local MetricKit files, account state/ID, mail draft/contact,
translation source text, translation history, original image filename/path,
or crash install ID is automatically added. Chosen text/images can themselves
contain personal information; the user controls that content. The draft stays
in view state only, is discarded on dismissal, and is retained for retry after
a failed send. Sending snapshots the draft and locks editing/removal; image
loading disables submission/removal and checks cancellation before updating state.
No feedback queue, contacts field, fabricated identity, or debug submission
bypass is added. A 2xx response indicates accepted delivery; network/non-2xx
failures leave the form available for retry.

### Automatic crash diagnostics

`AITranslatorApp.init` starts the unchanged official `AirCrashReports.swift`
once, immediately after the existing local MetricKit reporter. Ordinary
production launches start it; XCTest environment/class markers and the existing
screenshot/UI-test launch mode suppress only the new automatic reporter.
It subscribes separately to MetricKit and never uploads the local reporter's
files, logs, hangs, metrics, history, account data, or mail drafts.

Each submitted crash body has exactly:

- `id`: random report UUID; `occurredAt`: diagnostic payload end time in ISO 8601,
  capped at now; `installID`: random UUID stored in standard UserDefaults,
  created per install and used only in crash reports to count affected installs.
- `app`: `{version, build, bundleID}`.
- `device`: `{model, os, osVersion, osBuild, arch, locale}`.
- `exception`: `{type, code, signal, name, message, terminationReason}`;
  missing values are explicit nulls. Names/messages are capped at 256/1024
  characters, termination reason at 512. Objective-C name/message require
  iOS 17/macOS 14 or later. Never put personal text into exception/trap messages.
- `threads`: up to 64 `{crashed, frames}` entries, crashed thread first with
  up to 256 frames, others up to 64. Each frame has `{image, uuid, offset,
  inApp}` and optional locally resolved `{symbol, symbolOffset}`.
- `images`: deduplicated binary descriptors `{name, uuid, inApp}`, **not photos**.

Crash JSON is bounded to 500,000 bytes by dropping deep frames/other threads.
System symbols are resolved on-device; application symbols require matching
dSYMs at AirFeedback. A failed delivery waits on disk in the app's caches,
with at most **20** queued reports; the next launch retries. The existing
server crash-enabled setting is not modified (a disabled host responds 202,
which drops the queued report). Release dSYM availability/upload was not changed
or validated here; no archive, upload, distribution, or service mutation occurs.

MetricKit delivers real diagnostics to a **later launch**, often only within a
day, including crashes in the first session. Simulator supplies **no crash
diagnostics**. A simulator form submission can check ingestion/error handling,
not verified App Attest or real crash capture. No physical-device crash,
verified production proof, backend ingestion, symbolication, or queue replay
was exercised by the implementation's static checks.

### Privacy manifest

Main-app `PrivacyInfo.xcprivacy` adds `NSPrivacyCollectedDataTypeCustomerSupport`
(User Content / Customer Support, manually submitted text),
`NSPrivacyCollectedDataTypePhotosorVideos` (optional user-selected images), and
`NSPrivacyCollectedDataTypeCrashData` (automatic diagnostics), each with
`NSPrivacyCollectedDataTypeLinked = false`,
`NSPrivacyCollectedDataTypeTracking = false`, and purpose
`NSPrivacyCollectedDataTypePurposeAppFunctionality`. Existing UserDefaults
reasons `CA92.1` and `1C8F.1` remain unchanged; `CA92.1` covers the new local
crash/proof defaults. No tracking is added. This source declaration does not
publish changes to the policy website or App Store Connect privacy labels;
those remain separate owner-reviewed release work.
