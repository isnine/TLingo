# 源语言与目标语言适配逻辑

> 本文档梳理 TLingo 在三个翻译引擎（Apple Translate / Google Translate / AI 模型）上对**源语言**与**目标语言**的解析、检测、回退与拒绝策略。
>
> 相关代码：
> - `ShareCore/Utilities/SourceLanguageDetector.swift` — 语言检测核心
> - `ShareCore/UI/HomeViewModel.swift` — 引擎分诊与短路
> - `ShareCore/Networking/AppleTranslationService.swift` — Apple Translate 服务封装
> - `ShareCore/Networking/GoogleTranslateService.swift` — Google Translate 服务封装
> - `ShareCore/Networking/LLMService.swift` — AI 模型 LLM 调用

## 总体原则

| 维度 | 策略 |
|---|---|
| **目标语言** | **永不自动重定向**，始终遵从用户在 UI 上选择的 `AppPreferences.targetLanguage`。`targetLanguageOverride` 仅用于"语言切换菜单单次覆盖"，消费一次后清空 |
| **源语言** | 若用户固定选择（非 `.auto`）→ 用用户选择；若 `.auto` → 用 `NLLanguageRecognizer` 检测，**排除 target 同语言**以避开混合语言误判 |
| **目标 == 源** | 在 Apple Translate 路径**前置短路**，直接返回本地化错误"Source and target are both <Language>. Pick a different target language."。Google / LLM 不做此校验（可正常调用） |

## 共享检测层：`SourceLanguageDetector`

### `detectLocaleLanguage(of:)` — 基础检测

- 用 `NLLanguageRecognizer`，约束在 20 种应用支持的语言
- `languageHints` 给常见语言加先验（英文 2.0、简中 1.5、日 0.6 等）
- 短文本判定：≤10 字符 **或** ≤3 词 → 阈值提高到 0.5（默认 0.3）
- 对中文做 `correctChineseScript`：当 `Locale.preferredLanguages` 只含简中或繁中时，把另一种纠正过来（`NLLanguageRecognizer` 对短 Han 文本无法可靠区分脚本）

### `detectLocaleLanguage(of:excludingTargetCode:)` — 排除 target 检测

针对"`你好, hello`"这类混合输入，让检测**偏向非 target 那一种**：

1. 跑同样的 NL 识别拿前 5 个 hypotheses
2. 跳过 base language 与 target 相同的候选
3. 候选必须同时满足两个门槛才被采纳：
   - **绝对门槛**：confidence ≥ 0.15
   - **相对门槛**：confidence ≥ 被排除 top × 0.3
4. 都不满足 → 回退到 unfiltered top（承认 source==target）；top 也不达阈值 → 返回 nil

**示例**：
- `"hey"` + target=en → `{en:0.79, tr:0.08, ...}` → tr 过不了绝对门槛 → 回退 top en（后续会被 source==target 短路拒绝）
- `"你好, hello"` + target=en → `{en:0.7, zh:0.25}` → zh 通过相对门槛 (0.7×0.3=0.21) → 选 zh

### `languagesAreSame(_:_:)` — BCP-47 同语言判定

| 输入 | 结果 |
|---|---|
| `en` vs `en` | true（exact） |
| `en` vs `en-US` | true（base 相同） |
| `en` vs `en-Latn` | true（Latn 是 en 的默认脚本，被忽略） |
| `zh-Hans` vs `zh-Hant` | true（多脚本语言被有意视作同语言） |
| `pt` vs `pt-BR` | true（base 相同） |
| `sr-Cyrl` vs `sr-Latn` | true（双方都带 script） |
| `en` vs `fr` | false |

`defaultScript(forLanguageCode:)` 维护"默认脚本"白名单，避免 `Locale.Language.minimalIdentifier` 在不同 OS 版本上行为不一致。

### `fallbackSourceLanguage(userPreference:)` — 三级回退

当 Apple Translate 必须传一个 source 但检测失败时使用：

1. 用户首选 `sourceLanguage`（非 `.auto`）
2. 系统首选 `Locale.preferredLanguages` 中第一个被 `SourceLanguageOption` 识别的
3. 兜底英文

## HomeViewModel 的分诊：`consumeResolvedTarget(for:)`

每次翻译请求统一从此入口拿到 `ResolvedLanguagePair { target, sourceCode }`：

```
target = targetLanguageOverride ?? AppPreferences.targetLanguage
                ↑ 消费一次即清空
sourceCode = detectSourceCode(for: text, excluding: target)
              ├─ 用户固定 → preferences.sourceLanguage.rawValue
              └─ .auto    → SourceLanguageDetector.detectLocaleLanguage(of:excludingTargetCode:).minimalIdentifier
```

`detectedSourceLanguage` 同步写回 `@Published`，UI 上自动显示"删除线 Auto + 检测到的语言"指示。

## 三引擎适配

### 1. Apple Translate

| 项 | 行为 |
|---|---|
| **源语言传参** | `Locale.Language(identifier: resolved.sourceCode)`；nil 仅当 `.auto` 检测失败 |
| **服务内部回退** | `AppleTranslationService.translateWithInstalledLanguages` 在 source 为 nil 时再跑一次 detect，最后兜底走 `fallbackSourceLanguage()` |
| **目标语言传参** | `resolvedTarget.localeLanguage`（用户选择，永不重定向） |
| **`source == target` 短路** | `sameSourceAndTargetResult(sourceCode:target:)` 在调用 API 前判定，命中则立即生成 `LocalProviderError.sameSourceAndTarget(language:)` 失败结果，不调系统 API。文案本地化："Source and target are both English. Pick a different target language." |
| **路径选择** | 1. 短路命中 → 立即失败<br>2. 调 `languageAvailabilityStatus(source:target:)`：<br>　- `.installed` 或（source nil 且 `.supported`）→ `TranslationSession(installedSource:target:)` 直接翻译<br>　- 其他 → 走 SwiftUI `.translationTask` 桥（macOS `AppleTranslationWindow`）触发下载 UI；若 10s 内 `.translationTask` 未触发 → 超时失败 |
| **失败日志** | 所有失败分支都用 `logger.error`：service 层 prepareTranslation/translate/translations 的 do-catch、HomeViewModel installed-pack catch、watchdog timeout、bridge 不支持的语言对、`languageAvailabilityStatus` 返回 unsupported 等 |

### 2. Google Translate (GTX)

| 项 | 行为 |
|---|---|
| **源语言传参** | `resolved.sourceCode`；为 nil 时服务端用 `sl=auto` 自动检测 |
| **目标语言传参** | `resolvedTarget.rawValue`，经 `mapToGoogleCode`（`zh-Hans`→`zh-CN`、`zh-Hant`→`zh-TW`、`pt-BR`→`pt`） |
| **`source == target` 短路** | 不做。Google 服务端会原样返回（实际等同于无操作），不会报错 |
| **网络层** | `URLSession` 直接打 `https://translate.google.com/translate_a/single` GTX 端点，无密钥 |

### 3. AI 模型 (LLM, 通过 Cloudflare Worker → Azure OpenAI)

| 项 | 行为 |
|---|---|
| **源语言传参** | LLM 不直接接受语言代码。检测结果通过 `resolved.sourceLanguageDescriptor`（如 `"日本語 (Japanese)"`）注入 system prompt |
| **目标语言传参** | `resolved.targetLanguageDescriptor`（如 `"English"`）注入 system prompt |
| **占位符替换** | `PromptSubstitution.substitute` 替换 action prompt 中的 `{targetLanguage}`、`{sourceLanguage}` 和 `{appLanguage}`；`{appLanguage}` 使用当前 App 语言的英文描述 |
| **`source == target` 短路** | 不做。LLM 通常会顺其自然地给出相同输出或轻微改写，不会报错 |
| **流式** | SSE，`URLSession.bytes(for:)` 增量解析；句对/语法检查走 `response_format: json_schema` 结构化输出 |

## 关键决策与权衡

### 为什么目标语言永不重定向

历史方案曾在 source==target 时尝试切到系统第二语言（如英用户输入英文 → 自动切日文）。问题：
- 用户对"我把目标设成 English 你为什么给我日文"困惑度极高
- 与所有同类竞品行为不一致
- 让 UI 状态（"已重定向"角标）变得复杂

新策略：**目标 100% 听用户的**，仅 Apple Translate 在 source==target 时显式报错引导用户改 target。Google / LLM 容忍 same-language 调用。

### 为什么 detectExcluding 要双门槛

单门槛 0.05（早期实现）会让"hey" → 0.79 en, 0.08 tr 这种**单语主导**输入被错判成噪声候选 tr。
- 绝对门槛 0.15 拒绝纯噪声
- 相对门槛 0.3×top 区分"真正混合"（top 0.7 / next 0.25）vs "噪声"（top 0.79 / next 0.08）

### 为什么 `defaultScript` 是手写表

Apple `Locale.Language` API 在不同 macOS 版本对默认脚本的处理不一致：
- macOS 15+ 的 `NLLanguageRecognizer` 返回 "en" 时，`Locale.Language(identifier:"en").script?.identifier` 是 `"Latn"`
- `maximalIdentifier` / `minimalIdentifier` 在不同 OS 上行为漂移

为了让 `"en"` 和 `"en-Latn"` 稳定地被判为同语言，对常见语言显式列出默认脚本。`zh`、`sr`、`mn`、`az` 等真正多脚本语言**故意不列入**白名单，以保留它们的脚本区分能力。

## 失败排查清单

观察日志（subsystem `com.zanderwang.AITranslator`）：

| Category | 关键日志 | 说明 |
|---|---|---|
| `SourceLanguageDetector` | `detect text='...' hypotheses=[...] → '...' (confidence ...)` | 基础 detect 决策链 |
| `SourceLanguageDetector` | `detectExcluding(target=...) hypotheses=[...] → '...' rejected (...)` / `→ picked '...'` | 排除-target 决策链，含拒绝原因 |
| `AppleTranslation` | `Apple Translate: source==target (...), short-circuiting` | 短路命中 |
| `AppleTranslation` | `languageAvailabilityStatus: ... = unsupported` | 系统拒绝该语言对 |
| `AppleTranslation` | `Apple Translate watchdog fired — .translationTask() did not respond in 10s` | macOS bridge 超时 |
| `AppleTranslation` | `translate: prepareTranslation failed: ...` | 系统 API 抛错（含原始 TranslationError） |

## 单元测试覆盖（建议）

抽离 `resolveAutoSourceLanguage(text:targetCode:preferredLanguages:)` 纯函数后，可覆盖：

- `"hey"` + target=en + preferred=[en] → `en`
- `"你好, hello"` + target=en + preferred=[en, zh-Hans] → `zh-Hans`
- `"你好, hello"` + target=zh-Hans + preferred=[en, zh-Hans] → `en`
- `"你好"` + target=en + preferred=[zh-Hant] → `zh-Hant`（脚本纠正）
- 纯 ASCII 短串 + target=zh-Hans → `en`
- empty / whitespace → nil
- `"pt"` 输入 + target=pt-BR → 不应触发"切换"（base 相同）
