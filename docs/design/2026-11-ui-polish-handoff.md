# TLingo iOS UI 打磨 — 实现交接

设计稿（Design 画布）：https://claude.ai/code/artifact/40330ec8-d484-4922-b6c2-5e4e981562eb
原始截图：`~/Documents/Codex/TLingo-UI-参考图-2026-11-19 2/`（01–17）

范围：只做 iOS / iPadOS。macOS 外观规则见 `design-system`，不在本次范围内。
文案全部走 String Catalog（中文为主，英文同步）。

## 通用原则（遵守 design-system README）
- 只用 token：`accent` / `accent-fill` / `on-accent`、`card-background`、`chip-secondary-background`、`TLingoSpacing`、`TLingoRadius`（continuous）。不写新的硬编码颜色。
- 浮层 chrome 用 `tlingoGlassSurface / Capsule / Circle`（.chrome / .control / .prominent / .destructive）。内容卡片保持实色，不用玻璃。
- 颜色要克制：除主题色选择器外，不出现彩色图标底块。图标统一用 SF Symbols，`textSecondary` 色。
- 不是聊天 app：结果页不要出现“继续输入”式的输入框。

## 1. 首页（ios/ShareCore/UI/Home/HomeView*.swift）
- 顶部：历史按钮 ｜“文本 / 实时”分段切换（**没有“图片”tab**）｜设置按钮。实时 = 进入 RealtimeView。
- 语言栏：大号白色胶囊，swap 按钮用 accent 浅底。
- 输入框（composer, .chrome glass）：模型胶囊 · 扫描按钮（图片识别入口，原 ImageTextInputButton）· “听译”带文字的 prominent 胶囊（**保留文字，不要只放图标**）。
- 操作 chips：翻译 / 语法检查 / 润色 / 简化（沿用现有 Actions 配置）。

## 2. 多模型结果（HomeView+Results.swift, ProviderResultCardView.swift）
- 主结果单独一张大卡（md-body-prominent），标签取决于排序设置：
  - 按模型顺序 → “首选模型”
  - 按出结果顺序 → “最快 · {秒数}”
- 下面是“其他 N 个模型”分组，右侧是排序切换菜单（按模型顺序 / 按出结果顺序）。
- **每个模型卡都保留朗读和复制按钮**（不能只给主结果）。
- 结果页不显示原文那一行。
- 底部两个按钮：“编辑原文”（回到输入框，带上原文）/“新翻译”（清空）。不要做聊天式的输入框。

## 3. 长文多模型（新功能）
- 判断规则（建议，可调）：任一译文渲染高度超过约 8 行，或原文有 ≥2 段，就切到长文布局；否则沿用堆叠卡片。用渲染高度判断，不按字数。
- 顶部是“阅读 / 对比”分段切换。
  - 阅读：一次显示一个模型的全文，顶部用横向胶囊切换模型；原文折叠成 2 行加“展开”；底部是“复制全文 / 新翻译”。
  - 对比：按原文换行切段，每段显示原文 + 各模型译文；用户选用的那条加 accent 描边；和选用结果不同的词高亮；完全相同的折叠成“与 X 相同”；底部是“上一段 / 下一段”。
- 画布里长文页的绿色小圆点没有定义含义，**不要实现**。

## 4. 实时（ios/AITranslator/Realtime/RealtimeView*.swift, RealtimeSetupPromptView）
- 待开始：中间是大号圆形 prominent 麦克风按钮，下面是“双语 / 仅译文 / 仅原文”分段切换；**语言选择放在底部的 glass 栏里**（拇指可达）。
- 语言对不受支持时，在底栏上方显示 `error` 色图标 + 文字（例如“Apple Translate 不支持 English 到 简体中文，已改用 X”）。
- 进行中：顶部显示“● 收听中 mm:ss”；字幕用衬线体（New York）；最新一句最大，旧句逐渐变淡；底栏是波形 + 语言/模式 + 暂停(.control) + 结束(.destructive)。
- 暂停：底栏变成“已暂停”+“继续收听”prominent 胶囊 + 结束。
- 双语有两种布局，由“实时选项”里的“逐句对照”开关控制：
  - 开：每句原文（小号灰字）下紧跟译文（大字）；还在识别的句子先显示“正在翻译…”占位。
  - 关：上面原文区、下面译文区（稍大），各自左右翻页，中间用 page dots。**不加“原文/译文”标签，也不显示页码**。
- 实时选项 sheet：字幕（显示模式分段 / 逐句对照开关 / 字幕外观）、输入（麦克风 | iPhone 音频 / 语音识别）。

## 5. 模型选择 sheet（ios/AITranslator/UI/Models/ModelsView.swift）
- 分两组：“首选模型”（单选，带“更换”）和“同时对比（已选 N 个）”（多选）。保留 PRO / LATEST 标签。

## 6. 历史（ios/AITranslator/UI/History/HistoryView.swift）
- 大标题“历史”，搜索框置顶；顶部是“文本 / 实时”分段切换，右上角保留“…”菜单。
- 文本行：译文作标题，原文作副标题，下面一行元信息“EN → ZH · 润色 · 4 个模型”。
- 实时行（RealtimeHistoryRow）：结构不变（波形图标、自动标题、时间、预览、时长、方向），已优化的会话加一个 accent 色文字“已优化”。

## 7. 实时历史详情（RealtimeHistoryDetailContent.swift, RealtimeHistoryAudioTimelineView.swift）
- 头部：标题 + metaLine，右侧是版本菜单胶囊（实时草稿 / 已优化）。
- 只有草稿时，显示一张“提升转写准确度 · 优化”卡片（对应 Improve with MOSS；用户可见文案里是否露出 “MOSS” 待定，暂时不露出）。
- 草稿版：逐句列表，左侧是 accent 色时间戳（点击跳转），当前播放句用浅 accent 底高亮。
- 已优化版：说话人对话气泡，左右交替，带“编辑说话人名称”。
- 底部浮动 glass 播放条：播放/暂停、进度、时间，以及音源菜单胶囊。
- “…”菜单保持现有项：复制 / 编辑说话人 / 重建字幕 / 导出。

## 8. 图片识别（ImageTextInputButton → 结果）
- 入口只保留输入栏的扫描按钮。
- 结果卡片：“识别到 N 段文字”，按钮“复制原文 / 复制译文 / 重新识别”；底部是“拍照 / 从相册选择”。
- 未找到文字：在页面内提示，不用 alert；不显示照片预览；按钮为“重新拍照 / 换一张照片”。

## 9. 设置（ios/AITranslator/UI/Settings/SettingsView.swift）
- 用原生 grouped Form。**图标统一用灰色 SF Symbol，不加彩色底块**。
- 顶部订阅卡片：浅灰 Pro 标识 + “TLingo Pro / 已启用 · 所有模型可用” + 管理。
- 翻译：模型（右侧显示当前值）、结果排序（新增，对应第 2 节）、管理操作、朗读声音。
- 系统：默认翻译应用 + 说明 footer。
- 外观：主题颜色（8 色）+ 实时预览、阅读样式、外观模式。
- 通用：保存翻译历史、帮助与反馈、关于。开发者放在最底部。
- 新增项（外观模式 / 保存历史 / 帮助 / 关于）如果代码里还没有对应功能，先确认再加。

## 验证
- 每个改动的界面都在浅色、深色、Reduce Transparency、Reduce Motion、最大 Dynamic Type 下检查一遍。
- 现有测试保持全绿（见 docs/verification.md）。
