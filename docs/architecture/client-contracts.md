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
- Apple 翻译的中文繁简互转使用 Foundation 本地字形转换，语言对视为本地可用，无需语言包或 TranslationSession；结果标注为本地繁简转换，支持逐句对照。该路径不承诺地区用语本地化，也不切换云端供应商；其他语言对保持系统翻译路径。
- 文本输入框中单独按 Tab 交换源语言和目标语言，不提交翻译；输入法组合文字或带修饰键时不拦截。
- 结果排序偏好保存在 App Group UserDefaults（`model_result_order`），不通过 iCloud 同步；默认按首次出现结果的时间升序（`firstCompletedFirst`，出结果后位置固定，不随完成或失败跳动），可选按模型列表顺序（`modelList`）。
- 首次安装且未保存模型选择时，默认启用微软翻译和 AI 模型目录中的第一个免费模型（目录顺序），不启用付费模型。
- 免费用户点击另一个免费云端 AI 模型时，直接替换当前免费云端模型，不要求先取消旧选择；其他翻译服务、Apple Intelligence、自定义端点及已保存的锁定付费选择保持不变。会员仍可多选，取消最后一个模型时仍保留可用默认模型。
