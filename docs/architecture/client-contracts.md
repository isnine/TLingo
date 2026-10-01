---
status: current
owner: architecture
verified_commit: initial
review_triggers:
  - Swift endpoint changes
  - HMAC or OAuth changes
---

# 客户端契约

云端 Worker 不在本仓库。本文只记录客户端依赖的外部契约；改变签名形状或 wire format 需要兼容已发布的客户端。

## Host 与路径

- `AppSecrets.cloudEndpoint` 指向 API host（生产为 `https://tlingo.zanderwang.com/api`）。
- 客户端请求 `/api/<internal-path>`，签名使用不含 `/api` 的 internal path。
- Direct 更新资源位于 `updates.tlingo.zanderwang.com`。

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
| `/oauth/token` | PKCE / refresh token |

模型 ID 含 `/` 时作为多级路径请求（如 `/api/qwen/qwen3.7-flash/chat/completions`），HMAC 对完整路径签名。

## 模型目录

`/models` 返回的 `tags` 是有序字符串数组。可选 `tagStyles` 按标签文字匹配，每项可提供 `textColor` 和 `backgroundColor`（`#RRGGBB`）；缺省或无法解析时使用默认颜色。

## 微软翻译

`POST /api/translate/microsoft` 接收 `{text, sourceCode?, targetCode}`，省略源语言时自动检测，返回 `{text}`。文本上限 50000 UTF-16 code units。

## OAuth（Direct）

App 生成 state 与 PKCE challenge 打开 Web 激活页；Web 完成邮箱 OTP 后通过 custom URL 回调 App；App 以 verifier 调用 `/oauth/token` 换取 tokens 和 entitlement。

Token JSON 使用 snake_case。`invalid_grant` 表示当前凭证不能继续使用；刷新失败不清除本地权益，在已保存有效期内继续有效。

## 客户端行为约定

- 文本输入框中单独按 Tab 交换源语言和目标语言，不提交翻译；输入法组合文字或带修饰键时不拦截。
- 结果排序偏好保存在 App Group UserDefaults（`model_result_order`），不通过 iCloud 同步；默认按首次出现结果的时间升序（出结果后位置固定，不随完成或失败跳动），`modelList` 按模型列表顺序。
