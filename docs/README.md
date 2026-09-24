---
status: current
owner: repository
verified_commit: initial
review_triggers:
  - architecture changes
  - documentation additions or retirement
---

# TLingo 文档索引

本目录只保留客户端的当前规范与操作手册。代码、配置和测试是事实来源；文档冲突时先验证当前实现。云端 Worker 与 Web 不在本仓库中。

## 架构

- [`architecture/ios-overview.md`](./architecture/ios-overview.md)：iOS target、状态 ownership 和热点。
- [`architecture/ios-invariants.md`](./architecture/ios-invariants.md)：iOS request、Realtime、History 和配置不变量。
- [`architecture/client-contracts.md`](./architecture/client-contracts.md)：客户端与云端 API 的契约。

## 验证与发布

- [`verification.md`](./verification.md)：按变更范围选择构建和测试。
- [`ios-agent-workflow.md`](./ios-agent-workflow.md)：iOS App 编译、运行、交互和运行时验证流程。
- [`direct-release.md`](./direct-release.md)：Direct 构建、签名、公证和 Sparkle 发布流程。

## 领域文档

- [`language-resolution.md`](./language-resolution.md)：源语言和目标语言解析。
- [`local-mlx-inference.md`](./local-mlx-inference.md)：本地推理集成。
- [`Swift Style Guide.md`](./Swift%20Style%20Guide.md)：Swift 代码风格。
- [`PrivacyPolicy.md`](./PrivacyPolicy.md)、[`TermsOfUse.md`](./TermsOfUse.md)：隐私政策与使用条款。

## 文档状态

- `current`：已对 `verified_commit` 验证，可作为当前规范。
- `historical`：历史方案或执行记录，不再描述当前实现。
- `draft`：尚未确认，不得作为实现依据。
