# Local MLX Inference (Gemma 4 E2B) — 集成笔记

本文记录将 PhoneClaw 项目中的 MLX 本地推理能力移植到 AITranslator (TLingo) macOS 版的完整过程，包括架构决策、踩坑记录和关键修复，供后续复用或扩展参考。

---

## 架构概览

```
AITranslator (macOS)
  └─ LocalModelsView.swift          ← Models tab 的本地模型 UI（下载/勾选）
  └─ ShareCore/LocalLLM/
       ├─ Core/
       │    ├─ MLXLocalLLMService.swift    ← 核心推理服务（从 PhoneClaw 复制）
       │    ├─ BundledModel.swift          ← ModelRuntimeProfile + LinearBudgetFormula
       │    ├─ RuntimeBudgets.swift        ← 内存预算计算（纯函数）
       │    ├─ MLXTokenizersLoader.swift
       │    └─ MemoryStats.swift
       ├─ Installation/
       │    ├─ ModelDownloader.swift       ← URLSession 下载，3 源 fallback
       │    ├─ ModelInstaller.swift        ← 含 deleteModel(id:)
       │    ├─ ModelInstallState.swift     ← 状态枚举 + ModelDownloadMetrics
       │    └─ ModelPaths.swift            ← 路径解析
       ├─ Gemma4/
       │    ├─ Gemma4Registration.swift
       │    ├─ Gemma4Model.swift
       │    ├─ Gemma4Config.swift          ← 需要 import CoreGraphics（CGSize）
       │    └─ ...
       └─ LocalTranslationService.swift   ← macOS-only 适配层，桥接 LLMService

  └─ InferenceKit/                        ← 本地 SPM package（从 PhoneClaw 复制）
       └─ Package.swift                   ← mlx-swift 依赖改为本地路径
```

## 依赖管理

mlx-swift 和 swift-tokenizers 通过**本地路径**引用，指向 PhoneClaw 的 DerivedData checkouts，避免重复网络下载：

```
~/Library/Developer/Xcode/DerivedData/PhoneClaw-<hash>/SourcePackages/checkouts/mlx-swift
~/Library/Developer/Xcode/DerivedData/PhoneClaw-<hash>/SourcePackages/checkouts/swift-tokenizers
```

> **注意**：如果 PhoneClaw 的 DerivedData 被清理，构建会失败，需要更新 `InferenceKit/Package.swift` 和 `project.pbxproj` 里的本地路径。

## 平台隔离

所有本地模型代码用 `#if os(macOS)` 包裹：
- `LocalTranslationService.swift` 整文件
- `LocalModelsView.swift` 整文件
- `ModelsService.localModels` 静态变量
- `LLMService.sendModelRequest()` 中的本地路由分支

iOS 构建不受影响，继续使用云端模型。

---

## 关键集成点

### 1. ModelConfig.isLocal

```swift
// ShareCore/Configuration/ModelConfig.swift
public let isLocal: Bool  // 默认 false，init(from decoder:) 始终 false，向后兼容
```

### 2. ModelsService.localModels

```swift
static var localModels: [ModelConfig] {
    #if os(macOS)
    return [ModelConfig(id: "local-gemma-4-e2b-it-4bit", displayName: "Gemma 4 E2B · 本机",
                        isDefault: false, isPremium: false, supportsVision: false,
                        tags: ["local"], hidden: false, isLocal: true)]
    #else
    return []
    #endif
}
```

在 `getCachedModels()` 和 `fetchModels()` 返回时都要 append `localModels`。

### 3. LLMService 路由

```swift
// ShareCore/Networking/LLMService.swift — sendModelRequest() 开头
#if os(macOS)
if model.isLocal {
    return try await LocalTranslationService.shared.translate(
        text: text, action: action, targetLanguage: targetLanguageDescriptor,
        partialHandler: partialHandler)
}
#endif
```

### 4. ModelsView 过滤

本地模型不应出现在云端 Free/Premium 分区，也不应计入免费模型限制：

```swift
private var freeModels: [ModelConfig] {
    models.filter { !$0.isPremium && !$0.hidden && !$0.isLocal }
}
// hiddenFreeModels / premiumModels / hiddenPremiumModels 同样加 && !$0.isLocal

private var hasReachedFreeLimit: Bool {
    let freeModelIDs = Set(models.filter { !$0.isPremium && !$0.isLocal }.map(\.id))
    ...
}
```

---

## 踩坑记录

### 坑 1：@Observable + SwiftUI 不重渲染

**现象**：下载进度 UI 卡住，按钮状态不更新。  
**原因**：`@State private var mlxService = LocalTranslationService.shared.mlxServiceObservable` 捕获了引用，但 SwiftUI 的依赖追踪没有挂上。  
**修复**：改用计算属性，每次访问都重新读取，让 SwiftUI 正确追踪 `@Observable` 内的属性变化：

```swift
// 错误写法
@State private var mlxService = LocalTranslationService.shared.mlxServiceObservable

// 正确写法
private var mlxService: MLXLocalLLMService {
    LocalTranslationService.shared.mlxServiceObservable
}
```

### 坑 2：勾选立刻被取消

**现象**：在 Models tab 勾选本地模型，立刻恢复未勾选状态。  
**根因**：`HomeViewModel.updateEnabledModels()` 在每次 `enabledModelIDs` 变化时触发。它用 `currentEnabled.intersection(availableIDs)` 过滤——当 `fetchModels(forceRefresh: true)` 的 30 秒防抖早返回路径（`minimumRefreshInterval`）返回的是裸 `cachedModels`（不含 local model）时，intersection 把 `local-gemma-4-e2b-it-4bit` 过滤掉，然后写回 preferences。

**修复**：`ModelsService.fetchModels` 里所有早返回路径都要 append `localModels`：

```swift
// 修复前（早返回，没有 local models）
if let cached, !cached.isEmpty, let lastFetch,
   Date().timeIntervalSince(lastFetch) < minimumRefreshInterval {
    return cached  // ← 缺少 localModels
}

// 修复后
if let cached, !cached.isEmpty, let lastFetch,
   Date().timeIntervalSince(lastFetch) < minimumRefreshInterval {
    return cached + ModelsService.localModels
}
```

同样要检查：`cachedModels`（锁内存储）只存网络结果，不含 `localModels`，所有对外返回路径都需要手动 append。

### 坑 3：Gemma4Config.swift 缺少 CoreGraphics

`CGSize` 在 macOS 需要显式 `import CoreGraphics`，PhoneClaw 里 UIKit 隐式导入了它。

### 坑 4：网络请求失败（App Sandbox）

Release Build 的 `AITranslator.entitlements` 缺少 `com.apple.security.network.client`，导致下载请求被沙箱拦截。Debug Build 无沙箱，不受影响。

---

## 输出 Token 上限说明

E2B 的 `textOutputBudget` 公式（`BundledModel.swift`）：

```
tokens = clamp(minTokens=384, max(0, headroom - 250MB) * 1.4, maxTokens=2048)
```

当可用内存 headroom ≤ 250 MB 时，输出上限降至最低值 **384 tokens**。翻译场景绰绰有余（一般 50–200 tokens）。日志中的「输出已达单次输出上限（384 tokens）」是内存紧张时的保守兜底，不是 bug。

---

## 模型存储路径

- **Debug（无沙箱）**：`~/Documents/models/gemma-4-e2b-it-4bit/`
- **Release（沙箱）**：`~/Library/Containers/com.zanderwang.AITranslator/Data/Documents/models/gemma-4-e2b-it-4bit/`

由 `ModelPaths.swift` 的 `modelDirectory(for:)` 解析。

---

## 下载源（3 源 fallback）

`ModelDownloader.swift` 按顺序尝试：
1. ModelScope（国内首选）
2. HuggingFace Mirror
3. HuggingFace 官方

---

## 验证清单

1. macOS Build 无编译错误
2. iOS Build 不受影响（`#if os(macOS)` 隔离完整）
3. Models tab 出现「ON-DEVICE MODELS」分区，local model 不在 Free/Premium 分区
4. 下载进度：百分比 + `X MB / Y MB` + 速度显示正常
5. 下载完成后可勾选，勾选状态持久化（重启 app 后仍然勾选）
6. 勾选后发起翻译，路由到本地模型（日志出现 `[MLX] model loaded`）
7. 取消勾选后路由恢复云端
