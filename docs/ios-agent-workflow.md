---
status: current
owner: repository
verified_commit: cdb42c09aa219df4ced4e333682d5f3d9ee7db7b
review_triggers:
  - iOS build workflow changes
  - simulator tooling changes
  - XcodeBuildMCP or sim-use behavior changes
---

# iOS Agent Workflow

在编译、安装、启动、操作或运行时验证 iOS App 前先阅读本文。构建与测试范围仍以
[`verification.md`](./verification.md) 为准；本文只记录工具分工、执行顺序和已验证的故障恢复。

## 工具分工

- 优先使用可用的官方 Xcode 无界面接口处理工程与构建；能力不足时使用 XcodeBuildMCP 或仓库已验证的命令。
- sim-use：UI 的 observe-act-verify、Accessibility 交互、进程消失检测和最终状态确认。
- XcodeBuildMCP `snapshot_ui`：sim-use 暂时拿不到 Accessibility 树时的补充观察手段。

不要把工具返回的“操作成功”当作 UI 已变化；每次交互后必须重新观察。

## 执行顺序

1. 读取对应工具的 skill。
2. 若选择 XcodeBuildMCP，首次调用前读取其 skill 并调用 `session_show_defaults`；复用本次已确认且未变化的配置。
3. 查找已启动的目标模拟器，并使用 UDID 固定设备。存在多个同名设备时，不要同时使用名称选择器。
4. 设置工程、scheme、configuration 和 simulator UDID。当前 iOS App 使用：

   ```text
   project: ios/AITranslator.xcodeproj
   scheme: TLingo
   configuration: Debug
   ```

5. 按 [`verification.md`](./verification.md) 选择最小构建门槛。只需要编译时使用 simulator build；需要 UI
   验证时，再安装并启动刚生成的 App。
6. 第一次设备交互前按 sim-use skill 执行 preflight（skill 目录下的 `scripts/preflight.py --device <UDID>`）。

7. UI 操作遵循 `observe -> act -> verify`。优先使用 Accessibility label、identifier 或 sim-use alias；坐标仅作为
   最后手段。
8. 完成后运行最小静态检查并查看最终 diff。报告未安装或未执行的检查，不得将其描述为通过。

## 已验证的故障恢复

### sim-use 报告旧进程消失

如果刚刚由构建流程主动重新安装或启动 App，旧 PID 消失属于预期。确认新进程正在运行后执行：

```bash
sim-use app-state --reset --device <UDID>
```

如果不是主动重启，按崩溃处理：停止交互、保留日志并报告，不要自动重新启动掩盖问题。

### sim-use 暂时返回空 Accessibility 树

先确认 App 进程仍在运行，再使用截图或 XcodeBuildMCP `snapshot_ui` 判断是 App 空白还是 Accessibility
读取异常。不要仅凭空树判断 App 已崩溃。树恢复后继续使用 sim-use 完成交互验证。

### 点击命令成功但页面没有变化

重新观察当前页面。若状态未变化，使用 sim-use 按稳定的 label 或 identifier 重试；不要重复使用已经过期的
element reference，也不要把工具层的成功响应当作产品行为验证。
若 sim-use 与 XcodeBuildMCP 的点击均未改变界面，可改用 `TLingoUITests` scheme 中的定向 XCTest
验证原生控件交互和重启持久化，不继续循环点击。

## 文档回写

每次使用本流程后，只在本次运行产生了可复现、证据充分且能改善后续执行的新发现时更新本文。更新时：

- 记录触发条件、可观察症状和已验证的恢复步骤。
- 删除被新证据推翻的旧结论，不叠加相互冲突的建议。
- 不记录临时 UDID、PID、时间戳、日志路径或只对单次运行有效的状态。
- 不复制 [`verification.md`](./verification.md) 已维护的构建矩阵。
- 没有新发现时不修改本文。
