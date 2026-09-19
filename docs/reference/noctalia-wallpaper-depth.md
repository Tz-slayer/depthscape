# 参考分析：Noctalia Wallpaper Depth

> 上游项目：<https://github.com/noctalia-dev/official-plugins/tree/main/wallpaper_depth>
> 版本：v1.0.4（plugin_api 26，2026-08-30）｜许可：MIT（插件）／Apache-2.0（模型）
> 本文基于源码通读（`service.luau` / `depth_helper.py` / `panel.luau` / `plugin.toml`）与官方文档整理。

---

## 1. 为什么必须研究它

depthscape 的原始设计文档在第 14.1 节把「Wayland surface 层级」列为最大风险，并留下一个二选一：

```text
Pure DMS Plugin
    or
DMS Plugin + Small DMS Core Patch
```

Noctalia 的 Wallpaper Depth 是**同一个想法的已上线实现**，它把这个问题的答案直接摆出来了：

> 它根本不做合成。它只生产一张 Mask PNG，然后把路径交给 shell core，
> 由 shell 自己把壁纸前景重绘在桌面 Widget 之上。

也就是说，Noctalia 选择的是「**shell core 提供 API**」这条路，而 DMS 目前**没有**这个 API。
这直接决定了 depthscape 的可行路径与工作量级，详见第 5 节。

---

## 2. 项目构成

| 文件 | 角色 |
|---|---|
| `plugin.toml` | 清单：1 个 service、1 个 panel、1 个 bar widget、3 个设置项 |
| `service.luau` | 常驻编排器：监听壁纸变化、排队、拉起 Python、回注册 Mask |
| `depth_helper.py` | CLI 子进程：`setup` / `status` / `generate` / `clear-cache`，stdout 输出 JSON |
| `panel.luau` | 设置面板：安装状态卡 + 各输出状态行 + 三个操作按钮 |
| `bar.luau` | 状态栏按钮，点击打开面板 |
| `translations/` | i18n，从第一天就有 |

注意技术栈差异：当前 Noctalia（v5+）**已经不再是 Quickshell 应用**（Quickshell 版是已归档的 v4），
它使用 Luau 作为插件语言、`noctalia.*` 作为宿主 API。因此不能照搬代码，只能照搬**设计决策**。

---

## 3. 数据流

```text
壁纸变化（每个 output 独立）
        │
        ▼
service.luau  syncOutputs()
        │  ① setWallpaperMask(output, nil)   ← 先清掉旧 Mask，避免残留
        │  ② enqueue(output, path, params)
        ▼
   pending 队列（单任务串行）
        │
        ▼
runAsync: .venv/bin/python depth_helper.py --data-dir <dir> generate
          --wallpaper <path> --threshold <t> --feather <f>
        │
        ▼
depth_helper.py
        ├── flock 独占锁（跨进程互斥）
        ├── sha256(壁纸) → 查 depth 缓存
        │     未命中 → ONNX 推理 → 归一化 → 存 .npy
        ├── guided filter 精修到原分辨率
        ├── smoothstep(threshold ± feather/2) → alpha PNG
        └── prune（depth 保留 8 份，mask 保留 32 份，按 mtime LRU）
        │
        ▼ stdout JSON { maskPath, cacheHit, elapsedMs, width, height }
        │
        ▼
service.luau  校验结果是否已过期 → setWallpaperMask(output, {path, wallpaperPath})
        │
        ▼
Noctalia shell core 合成：壁纸 → Widget → 壁纸前景（Mask 区域）
```

关键分界线：**Python 只负责产出资源，Luau 只负责调度，合成完全在 shell core。**

---

## 4. 值得直接照搬的十个设计决策

### 4.1 只用深度估计，不做主体分割

depthscape 原计划是「主体分割 + 深度估计」两个模型。Noctalia 只用了**一个**深度模型，
前景 Mask 直接由归一化深度图 + 阈值得到。

代价是效果语义变了：不是「人物遮挡 Widget」，而是「**靠近镜头的景物遮挡 Widget**」。
收益是巨大的：

- 一个模型，一次推理，缓存与依赖都减半；
- 不再依赖人像分割模型，动漫 / 风景 / 静物壁纸都能用；
- 用户可调阈值直接改变前景范围，交互模型极其简单。

> 对 depthscape 的建议：V0.1 先用纯深度方案跑通全链路，
> 把「主体分割」降级为 V0.2+ 的可选增强（用于人物壁纸的边缘精修），而不是前置依赖。

### 4.2 Guided filter 精修 —— 边缘质量的真正来源

这是整个项目里最容易被忽略、但最决定观感的一段代码（`refine_depth`）：

```text
粗深度图（518px）
    ↓ 双线性放大到 ≤1920px
    ↓ guided filter，guide = 原图灰度（LANCZOS 缩放）
    ↓ 半径 8，epsilon 0.001，box_mean 用积分图实现（O(1)/像素）
    ↓ 双三次放大回原分辨率
精修深度图
```

作用：把 518px 的模糊深度图上采样到 1080p/1440p 的同时，
**让深度边缘吸附到原图的亮度边缘上**。这就是为什么它没有分割模型，头发边缘却不会糊成一团。

纯 numpy 实现，无额外依赖，约 40 行。**强烈建议 depthscape 直接采用。**
它把「边缘质量」这个问题从「换更好的模型」变成了「加一个后处理」，性价比极高。

### 4.3 两级缓存：深度与 Mask 分离

```text
depth key = {sha256(壁纸)}-{MODEL_SHA256[:16]}-d{DEPTH_PIPELINE_VERSION}-i{INPUT_SIZE}
mask  key = {depth key}-v{MASK_PIPELINE_VERSION}-t{threshold:.4f}-f{feather:.4f}
```

拖动阈值 / 羽化滑块时，**只重算 smoothstep，不重跑模型**。
depthscape 文档里提的是单一 hash，这里拆成两级更正确——因为滑块的交互频率远高于换壁纸。

两个版本号（depth / mask pipeline）分开，使得改后处理算法时不必让模型缓存失效。

清理策略：depth 保留 8 份、mask 保留 32 份，按 `st_mtime_ns` 倒序裁掉多余的。

### 4.4 模型用文件 SHA256 固定，而不是用仓库 revision

```python
MODEL_REVISION = "4472b736..."          # 用于下载 URL
MODEL_SHA256   = "afb6a5c2..."          # 用于校验
MODEL_SIZE     = 99_060_839
```

下载流程：流式写入 `*.onnx.part` → 校验大小 → 校验 sha256 → `os.replace()` 原子改名。
任何一步失败都不会留下半个可用文件。**这套「下载即校验 + 原子落地」值得原样搬过来。**

### 4.5 自带隔离 venv，绝不污染系统 Python

```text
dataDir/runtime/.venv/           ← python3 -m venv --clear
dataDir/models/depth-anything-v2-small/model.onnx
dataDir/cache/depth/  cache/masks/
dataDir/setup.json  setup-operation.json
```

依赖固定版本：`numpy==2.4.2`、`onnxruntime==1.28.0`、`Pillow==12.3.0`，
安装参数带 `--only-binary=:all:` 与 `--no-user`
（`--no-user` 是为了对抗用户 `~/.config/pip/pip.conf` 里的 `user = true`，这是个真实踩过的坑）。

要求宿主 Python 3.11–3.14，用 `python3 -m venv` 引导，之后所有调用都走 venv 内的解释器。

### 4.6 单任务队列 + 陈旧结果二次校验

并发控制分三层：

1. **进程内**：`activeJob` 单例 + `pending` 队列 + `queued[outputName]` 去重键
   （键 = `wallpaperPath + "\n" + paramsKey`，同一目标同一参数不重复入队）；
2. **跨进程**：Python 侧 `fcntl.flock(LOCK_EX)` 锁 `runtime/generate.lock`；
3. **逻辑层**：任务完成后重新读取当前壁纸路径与参数键，与任务创建时的快照比对，
   不一致则**丢弃结果并重新入队**。

```lua
local stale = currentParameters == nil
  or currentParameters.key ~= completedJob.parametersKey
  or currentPath ~= completedJob.wallpaperPath
```

第 3 条正是 depthscape 文档里「支持取消旧任务，防止连续换壁纸造成任务堆积」的落地方式——
不是真的取消，而是**算完再判断要不要用**。实现成本极低，且天然避免竞态。

另外：壁纸一变立刻 `setWallpaperMask(output, nil)`，绝不显示上一张壁纸的 Mask。

### 4.7 用 JSON 操作文件做跨进程进度

`setup` 是一次长任务（建 venv + 下 99MB 模型），而 `runAsync` 在这里没挂回调。
于是约定：Python 把状态原子写入 `setup-operation.json`：

```json
{"state":"running","startedAt":...,"modelSize":99060839}
{"state":"ready","finishedAt":...,"modelRevision":"...","modelSize":...}
{"state":"error","finishedAt":...,"message":"..."}
```

service 以 1s 间隔轮询（`setUpdateInterval(1000)`），状态离开 `running` 就收尾。
**跨进程长任务的进度上报，用文件比用管道更省心**，因为没有粘包、没有缓冲区、天然可重入。

### 4.8 设置项只有三个

```toml
auto_generate = true      # 壁纸或参数变化时自动重算
threshold     = 30        # 0-100，归一化深度阈值；越低，越多景物挡在 Widget 前面
feather       = 8         # 0-50，阈值附近的过渡宽度
```

对比 depthscape 原文档里规划的六组设置树（General / AI / Occlusion / Parallax / Effects / Displays），
这个对比非常刺眼。**能自动推导的就不要暴露给用户。**
阈值和羽化是唯一真正需要人手调的参数，其余全部走默认。

内部转换：`threshold/100` 得 0–1，`feather/100` 得 0–0.5，
再以 `smoothstep(depth, t - f/2, t + f/2)` 生成 alpha——羽化是**对称**的，语义干净。

### 4.9 全程 CPU 推理，且每次新建 Session

```python
providers=["CPUExecutionProvider"]
```

没有 GPU 依赖，没有 CUDA/ROCm 分支，不挑机器。代价是每次 `generate` 都重建一次
`InferenceSession`（约几十毫秒加载开销），换来的是 shell 进程里不常驻任何模型内存。

对于「壁纸变化时才跑一次」的调用频率，这个取舍完全正确。**不要过早引入 GPU 后端。**

### 4.10 推理输入尺寸保持宽高比

```python
INPUT_SIZE = 518          # 37 × 14
MODEL_PATCH_SIZE = 14     # ViT patch 尺寸

scale = max(518 / w, 518 / h)          # 短边缩到至少 518
width  = max(518, round(w * scale / 14) * 14)   # 再对齐到 14 的整数倍
height = max(518, round(h * scale / 14) * 14)
```

不直接拉伸成正方形，避免变形导致深度失真；尺寸必须是 patch 的整数倍，否则 ONNX 会报 shape 错。
缓存命中时还会校验 `depth.shape == (model_height, model_width)`，不匹配就删缓存重算。

---

## 5. 关键缺口：DMS 侧没有对应的合成能力

这是本次调研**最重要**的结论。

### 5.1 Noctalia 提供了什么

```lua
noctalia.setWallpaperMask(outputName, {
  path = generated.maskPath,
  wallpaperPath = completedJob.wallpaperPath,
})
```

一行调用，插件就完事了。剩下的「把壁纸前景画到 Widget 上面」由 shell core 完成。
**层级问题的解法是：把它变成 core 的职责。**

### 5.2 DMS 现在有什么

| 能力 | 状态 |
|---|---|
| 当前壁纸路径 | ✅ `SessionData.wallpaperPath` |
| 壁纸变化信号 | ✅ `SessionData.onWallpaperPathChanged` |
| 桌面 Widget 渲染位置 | ✅ 桌面背景层（`background`），namespace `dms:desktop-widget:<plugin id>` |
| 插件自建 layer-shell surface | ❌ 文档明确：插件只能填充框架提供的插槽 |
| 壁纸 Mask / 前景层 API | ❌ 不存在 |
| layer 层级控制 / z-order API | ❌ 不存在 |
| input mask（点击穿透）API | ❌ 文档未提供 |

DMS 的插件类型只有 `widget` / `launcher` / `daemon` / `desktop` / `composite` 五种，
每一种的 surface 都由框架托管。**没有任何官方途径让插件在桌面 Widget 之上再叠一层。**

### 5.3 于是有两条路

> **本节是调研阶段的推理，已被实测部分推翻。** 保留原文是为了留下判断过程；
> 结论请看本节末尾的「实测修订」。
> 简言之：路线 B 走通了，但**成立的原因和这里写的完全不同**——
> 桌面 Widget 并不在 `background` 层，所以「`bottom` 层天然盖住 `background` 层」
> 这条论证是错的；真正起作用的是同层 map 顺序。路线 A 因此也不再是必需品。

**路线 A —— 向上游提案一个 Mask API（干净、但慢）**

照抄 Noctalia 的接口形态，向 DMS 提 PR / issue，请求 core 支持：

```text
DMS core 新增：setWallpaperMask(output, maskPath | null)
语义：在 Widget 层之上重绘壁纸的 Mask 区域
```

这是唯一「正确」的长期方案，也让 depthscape 从「需要打补丁的插件」变成「普通插件」。
但取决于 DMS 维护者的意愿与排期，不可控。

**路线 B —— 插件内直接创建 PanelWindow（脏、但能立刻验证）**

插件 QML 里 `import Quickshell` 是可用的，而 `PanelWindow` 是 Quickshell 的 QML 类型，
它会自行管理一个 layer-shell surface。理论上可以在插件组件内直接实例化：

```qml
PanelWindow {
    WlrLayershell.layer: WlrLayer.Bottom          // background 之上、普通窗口之下
    WlrLayershell.namespace: "dms:plugins:depthscape-fg"
    WlrLayershell.exclusionMode: ExclusionMode.Ignore
    // 输入区域置空 → 点击穿透，不影响下层 Widget 交互
}
```

依据：wlr-layer-shell 的层级顺序是
`background < bottom < top < overlay`，而**普通应用窗口位于 bottom 与 top 之间**。
所以放在 `bottom` 层的前景可以「盖住 Widget、又不盖住窗口」
——恰好是 iOS 景深锁屏的层级关系。

⚠️ 这一条**未经实测**，是待验证假设。文档没写不代表 QML 层面做不到，
但也可能被 Quickshell 或 DMS 的加载机制限制。**这是 V0.1 第一个要做的实验。**

### 5.4 如何验证层级

```bash
# Hyprland
hyprctl layers
# Niri
niri msg layers
```

起一个最小插件，只画一个半透明色块，确认它相对桌面 Widget 与普通窗口的位置关系。
**在写任何 AI 代码之前先做这一步**——如果层级不成立，后面全部工作都要重做。

---

### 5.5 实测修订（2026-09-19）

上面 5.2 / 5.3 的层级论证建立在一个错误前提上。真实会话里的实测结果：

| 原判断 | 实测 | 证据 |
|---|---|---|
| 桌面 Widget 在 `background` 层 | **在 `bottom` 层** | `niri msg layers` 与 `DesktopPluginWrapper.qml` 的默认分支；官方插件文档此处有误 |
| 前景放 `bottom` 就天然盖住 Widget | **不成立**，两者同层 | 同层没有层级关系可言 |
| `niri msg layers` 能判定 z-order | **不能**，它只是存在性/命名/层级归属的查询 | 层内顺序在输出里不可见 |

**真正起作用的机制是「同层 map 顺序」**：layer-shell 同层内，
最后 map 的 surface 画在最上面（smithay 的 `LayerMap` 是插入序 `IndexSet`，
niri 用 `layers_in_render_order()` + `.rev()` 压栈）。没有「提升」请求，
unmap + 重新 map 是唯一的杠杆。

这条规则在源码里是显式的，DMS 自己也依赖它——`DesktopWidgetLayer.qml` 在
Widget 列表变化时**重建**全部 Widget surface，就是在重新确立前后关系。
depthscape 用同一手段，并且因为 DMS 还有第二个重建触发点
（`pluginReadyKeyChanged`，每次 shell 启动都会触发），必须额外监听它，
否则前景会在启动时被压在 Widget 下面。

验证方式不是「看起来对不对」，而是拿真实遮罩做逐像素假设检验
（`tools/layer-stacking-test/probe.py`）：在 400×400 面板内比较
`MAE[前景在上]` 与 `MAE[Widget 在上]` 两个假设谁更接近观测值。
实测 bug 状态下 Widget 假设 MAE 0.00（像素级纯色，说明前景被完全盖住），
修复后前景假设 MAE 1.08；对照组（遮罩透明区）两次都是 0.63，说明测量本身没有漂移。

**对路线 A 的影响**：`setWallpaperMask` 这类 core API 依然是更优雅的长期形态
（省掉每个插件自己管 surface 顺序），但它**不再是 depthscape 能否成立的前提**。
depthscape 不依赖它，因此本项目不向上游提 PR，只把插件发布到插件商店。

---

## 6. 对 depthscape 的具体修订建议

| 原文档设计 | 建议修订 | 理由 |
|---|---|---|
| 主体分割 + 深度估计双模型 | V0.1 只做深度估计单模型 | 见 4.1，减一半复杂度，且泛化更好 |
| 单一 hash 缓存 | 拆成 depth / mask 两级缓存 | 见 4.3，滑块交互不必重跑模型 |
| 未提边缘处理 | 引入 guided filter 精修 | 见 4.2，性价比最高的观感提升 |
| 六组设置树 | V0.1 只暴露 threshold + feather | 见 4.8 |
| 「纯插件 vs 插件+补丁」待定 | 先跑 5.4 的层级实验定论 | 这是唯一的前置阻塞项 |
| 未提模型分发 | 采用「下载 + SHA256 校验 + 原子改名」 | 见 4.4 |
| 未提隔离环境 | 插件数据目录内建 venv | 见 4.5，避免污染系统 Python |
| 「取消旧任务」需求 | 用陈旧结果二次校验代替真取消 | 见 4.6 |
| 未提进度上报 | 用 JSON 操作文件 + 轮询 | 见 4.7 |
| 多显示器 | 每 output 独立状态机（Noctalia 已验证） | 原设计方向正确，可保留 |

### V0.1 修订后的定义

```text
① 层级实验：插件内 PanelWindow 放 bottom 层，能否盖住桌面 Widget？
        ↓ 成立
② 壁纸监听：SessionData.onWallpaperPathChanged → 取路径
        ↓
③ 单模型推理：Depth Anything V2 Small → 归一化深度
        ↓
④ guided filter 精修 → smoothstep(threshold, feather) → alpha PNG
        ↓
⑤ 三级缓存 + 下载校验 + Rust 单二进制引擎（原计划 venv，已放弃）
        ↓
⑥ 前景层用 Mask 绘制壁纸前景 → 视觉验证
```

其中 ① 当时被当成阻塞项，实测后确认成立（但成立机制与原推理不同，见 5.5）；
③④⑤ 是可以直接照抄的成熟方案；⑥ 已完成。

---

## 7. 一句话总结

> Noctalia Wallpaper Depth 证明了两件事：
> **AI 部分比预想的简单**（一个深度模型 + guided filter 就够了，不需要分割），
> **合成部分比预想的难**（它靠 shell core 提供 `setWallpaperMask` 才成立，而 DMS 没有）。
>
> 但 depthscape 最终发现 DMS 的缺口比想象中小：不需要 core 支持，
> 插件自建 `bottom` 层 surface 就能做到，代价是自己管理同层 map 顺序。
> 真正的工作量因此不在 AI、也不在「等上游」，而在**把同层顺序这件事测准**。
