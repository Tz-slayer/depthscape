# AGENTS.md — Depthscape

面向 AI 编码代理（Codex、Claude Code、Gemini 等）的项目开发与维护指南。在本仓库进行任何代码或配置变更时，必须严格遵守本文档所列出的规范与约束。

---

## 1. 项目简介与技术栈

Depthscape 是针对 **Dux Shell (DMS)** 与 **Niri** 合成器的深度感知壁纸插件，提供桌面组件景深遮挡（iOS 风格）与指针驱动的交互式 3D 空间壁纸效果。

- **UI 层**：QML / Qt6 + Quickshell，基于 DMS 的 `PluginSettings`、`qs.Common`、`qs.DCommon.Widgets`。
- **计算引擎**：Rust（`engine/`），基于 ONNX Runtime（`ort`）本地离线运行 Depth Anything V2 与 IS-Net / BiRefNet 模型，输出掩码与 3D 网格。
- **3D 渲染**：Qt Quick3D（`engine/spatial3d/`）。
- **合成器规则**：Wayland 命名空间 `^depthscape:`，需在 Niri 中配置 `place-within-backdrop true`。

---

## 2. 国际化规范（Internationalization & i18n）

为了保证在不同系统语言（如中文、英文等）环境下良好的本地化体验，插件内所有用户可见文案（界面标签、按钮、Tooltip、状态提示、Toast 通知、错误信息等）必须遵守以下国际化规范：

### 2.1. 名词优先复用原则（原生优先）

- **优先复用 dux-shell 原生词汇**：在编写 UI 文案、控件 Label 和常见操作时，尽可能选用 dux-shell (DMS) 官方既有的词汇与短语（例如 `"Settings"`、`"Reset to default"`、`"Cancel"`、`"Close"`、`"Display"`、`"Download"`、`"Enabled"`、`"Decrease"`、`"Increase"` 等）。
- **通用词汇调用方式**：对于完全属于 dux-shell 通用词库的词汇，统一使用 `I18n.tr(...)`。
  - 优势：直接命中 dux-shell 宿主全局词典，零成本复用宿主社区维护的多语言翻译，无需在插件中重复维护。

### 2.2. 插件独有词汇与翻译规范（私有词库）

如果该名词为插件独有概念、算法模型特定词汇或无法在 dux-shell 原生词库中复用的长句文案（例如 `"Depth Wallpaper"`、`"Occlusion Threshold"`、`"Edge Feather"`、`"Spatial Wallpaper"`、`"Depth Anything V2"` 等）：

1. **必须使用 `I18n.trFor("depthscape", ...)`**：
   - 严禁对插件私有词汇使用裸 `I18n.tr(...)`。
   - **原因**：DMS 的插件国际化机制中，裸 `I18n.tr()` 仅查找宿主全局词典，永远不会读取插件私有翻译；只有 `I18n.trFor("depthscape", "Term")` 才会优先查找本插件的本地翻译目录，并在未命中时回退到全局词典及英文原文。
   - 第一个参数必须为精确匹配 `plugin.json` 中 `id` 的字符串字面量 `"depthscape"`，不可传变量。

2. **单语言单文件规则（`translations/*.json`）**：
   - 所有插件独有的词汇，统一放置在插件根目录的 `translations/` 目录下。
   - **每一种语言使用一个独立的 `.json` 文件**，文件名对应目标区域语言代码（如简体中文为 `translations/zh_CN.json`、繁体中文为 `translations/zh_TW.json`、西班牙语为 `translations/es.json` 等）。
   - 严禁把多语言混写在一个文件中，严禁使用非标准目录名。

3. **词典 JSON 格式标准**：
   - 遵循 DMS 规范的两层 Context Bucket 结构，以英文原词作为顶层 Context 键名：
     ```json
     {
       "Depth Wallpaper": {
         "Depth Wallpaper": "景深壁纸"
       },
       "Occlusion Threshold": {
         "Occlusion Threshold": "遮挡阈值"
       },
       "Edge Feather": {
         "Edge Feather": "边缘羽化"
       },
       "Spatial Wallpaper": {
         "Spatial Wallpaper": "空间壁纸"
       },
       "Build failed (exit %1)": {
         "Build failed (exit %1)": "构建失败 (退出码 %1)"
       }
     }
     ```

4. **参数占位与动态字符串规范**：
   - 包含动态变量（如退出码、文件大小、进度等）的文本，**严禁使用字符串硬拼接**（如 `I18n.trFor(...) + "..."` 属于 i18n 反模式，破坏了多语言下的主谓宾语序）。
   - 必须在待翻译字符串中保留 `%1`、`%2` 等占位符，并通过 `.arg(...)` 填充动态变量：
     ```qml
     I18n.trFor("depthscape", "Download failed (exit %1)").arg(exitCode)
     ```

---

## 3. UI 与 QML 编码规范

1. **样式与主题**：
   - 严禁在 QML 中硬编码十六进制颜色值或魔数尺寸；必须引用 `Theme` 设计令牌（如 `Theme.surfaceColor`、`Theme.spacingM`、`Theme.fontFamily` 等）。
   - 控件布局和行卡片参考 `quickCapture` 与 Material 3 Expressive 规范（使用 `SettingsCard`、`SectionTitle`、`SettingDivider`、`Plugin*Row`）。
2. **事件穿透与层级陷阱**：
   - 带有 `ShaderEffectSource { hideSource: true }` 或 `ClippingRectangle` 的节点及其子节点无法接收鼠标事件；交互热区必须作为兄弟节点放置或放置在独立的交互顶层。
3. **逐屏配置隔离**：
   - 屏幕相关设置项（如开启状态、阈值、羽化等）必须绑定目标屏幕名称（如 `<key>_<screenName>`），确保多显示器独立生效。

---

## 4. 守护进程与引擎约束

1. **引擎解耦**：
   - QML 界面不得直接执行耗时阻塞的推理计算；计算任务统一由后台 Rust 引擎进程或 Daemon 处理。
2. **二进制容错与自动处理**：
   - 模型下载与引擎构建需具备异步状态跟踪及异常捕获能力，进程输出与失败原因必须经过恰当的国际化后提示用户。
3. **调试与日志**：
   - 探针与调试信息统一输出至 `console.warn`，避免普通 `console.log` 被 DMS 默认日志级别吞没。
