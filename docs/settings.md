# Depthscape 设置参考（含旧版设计存档）

> **状态提示**：本文第 0 节及以后描述的是另一版「多窗口 / 三栏工作室」UI，
> 当前 `experiment/background-layer` 分支**并未实现**。当前实现是一列 DMS
> 原生插件设置页，准确说明请看 [README](../README.md) 的
> *First run* / *Uninstalling and model cleanup* 两节。下面这一节与磁盘代码一致。
>
> 本文档当前以中文维护；英文版将在内容确认后提供。

## 当前设置项速查（以 `qml/DepthSettings.qml` 为准）

设置值由 DMS 存在 `~/.config/DankMaterialShell/plugin_settings.json`，
每个控件用 DMS 原生 `PluginSettings` 组件自动读写。

| settingKey | 控件 | 默认值 | 作用 |
| --- | --- | --- | --- |
| `targetScreen` | `SelectionSetting`（Display） | 聚焦输出 | 多屏时选择正在配置哪块屏幕；下面的景深设置都写入该屏的专属键 |
| `effectEnabled_<屏幕>` | `ToggleSetting` | `true` | 该屏的景深遮挡开关 |
| `threshold_<屏幕>` | `SliderSetting` | `30` % | 该屏的遮挡阈值 |
| `feather_<屏幕>` | `SliderSetting` | `8` px | 该屏的边缘羽化 |
| `spatialEnabled_<屏幕>` | `ToggleSetting` | `false` | 该屏的空间 3D 网格效果 |
| `modelType` | `DDropdown`（Model） | `small` | 深度模型 id，**全局**（模型只有一份），**只提供三个 Depth Anything V2 变体**（Small / Base / Large）；每个选项左侧用圆形图标表示下载状态——圆圈内的 ✓ 为已下载，空心圆为未下载 |

> 屏幕专属键**始终优先**于不带后缀的全局键（不再依赖 DMS 的"每个显示器单独壁纸"
> 开关）；没有专属键的屏幕回落到全局默认。页面没有预览窗口，工作区视差已下线。

`action` 是瞬时动作键，daemon 消费后立即清空：`install:<id>`、
`installForce:<id>`、`rescanEngine`、`generate`、`clearCache`、`uninstall`。
对应的 IPC：`dms ipc call depthscape install|installForce|rescan|generate|clearCache|uninstall|debug`。
`dms ipc call depthscape settingsProbe` 会在真实 DMS 进程里离屏实例化设置页，
返回每个控件与实际状态（无需打开窗口即可排查设置页加载问题）。

### 模型与数据

- 数据根由 `tools/resolve-data-root.sh <插件目录>` 决定：**全新安装**默认
  `<插件目录>/.data/`（DMS 卸载插件时随目录一起删掉模型）；**已有
  `$XDG_DATA_HOME/depthscape` 的安装**保持原位置，不迁移；`DEPTHSCAPE_DATA_DIR`
  可覆盖。模型在 `models/`，缓存 `cache/`，运行时 `runtime/`。
  daemon 的每次引擎调用都带 `--data-dir`，手动 CLI 也需带同样参数或环境变量。
- **按需下载**：安装、启用、切模型、换壁纸都不会触发下载。
  只有设置页的 *Download Model* / *Re-download Model* 或
  `depthscape-engine setup --model <id>` 会联网。缺模型时 `analyze` 直接报错。
- **清理**：设置页 *Remove Model Data*（二次确认）、
  `dms ipc call depthscape uninstall`、
  `depthscape-engine --data-dir <数据根> uninstall`。只删自己的三个子树与
  `widgets.json*`，数据根里其它文件保留。
- DMS 2.x 卸载插件时不调用任何插件代码，所以「卸载即自动删除」靠数据根位置实现：
  全新安装默认放在插件目录内，卸载即删；老安装（数据在 XDG 目录）卸载前请用上面的
  清理入口，或把 `DEPTHSCAPE_DATA_DIR` 指到插件目录内（见 README）。

### 首次使用顺序

1. 从插件商店安装（或软链）并启用插件 —— 不下载任何东西。
2. 设置页点 *Build Engine*（在插件目录的 `engine/` 里跑 `cargo build --release`，
   完成后自动重新检测）；手动构建后用 *Re-check Engine*。需要主机装有 Rust/cargo。
3. 在设置页选模型，点 *Download Model*。
4. 设置图片壁纸，遮罩自动生成；再按需要调阈值 / 羽化。

---

> **以下为旧版设计存档，勿按此操作当前版本。**

插件暴露的每一个选项：作用、默认值、在哪里改，都在这一页里。

有两个编辑入口，它们写的是同一份值：

* **设置界面** — DMS → Settings → Depthscape。下面列出的每个选项都在其中；
  与默认值不一致的行会出现 reset（重置）按钮。
* **布局文件** — 插件目录下的 `widgets.json`（与 `plugin.json` 同级，已在
  `.gitignore` 中忽略——它是本机状态，不是仓库内容）。文件被实时监听，改动
  即时生效，无需重启。这里只放 widget 的**摆放位置与逐实例覆盖**，见
  [Background widgets](#3background-widgets)。

> 0.3.0 之前布局文件存放在 `$XDG_DATA_HOME/depthscape/widgets.json`；插件启动时
> 会自动把旧文件迁移到新位置，旧文件保留不动。

插件级设置由 DMS 存放在
`~/.config/DankMaterialShell/plugin_settings.json`；一般不需要手动改这个文件。

### 逐屏隔离

显示配置按输出独立：`effectEnabled_<屏幕>`、`parallaxEnabled_<屏幕>`、`spatialEnabled_<屏幕>`、`spatialTravel_<屏幕>`、五个平移视差参数、`threshold_<屏幕>`、`feather_<屏幕>`、`fg_*_<屏幕>`，以及布局条目里的 `visible` / `occlude`。在 DP-3 上打开景深、平移视差或空间壁纸不会改动 DP-1。

不带屏幕后缀的 `effectEnabled`、`parallaxEnabled`、`threshold`、`feather` 等只作为“该屏幕还没有独立配置时”的默认值；设置界面在预览某个输出时只写该输出的键。`modelType` / `autoGenerate` 仍是全局的，因为模型文件只有一份。

---

## 0. 两个界面：预览面板与设置弹窗

设置内容比插件列表的一行装得下的多，所以拆成两层：

**内联面板**（Settings → Plugins → Depthscape 展开后看到的那块）
只显示一个**预览**——当前输出缩小后的桌面：壁纸、遮罩、以及摆在上面的
background widget。没有滑杆、没有表单。

把鼠标移到预览上，会出现两组东西：

* **顶部居中一个胶囊**，写着当前预览的是哪个输出（名称 · 分辨率）。
* **正中间三个独立的圆形按钮**：

| 按钮 | 作用 |
| --- | --- |
| `‹` | 切到上一个输出（多显示器时才有；单屏隐藏） |
| `⚙` | 打开独立设置弹窗 |
| `›` | 切到下一个输出 |

面板打开时默认落在你正在看的那个输出上，而不是列表里的第一个。

三个按钮用**同一套表面**：`surfaceContainerHighest` 92% + `outlineMedium` 描边 +
`surfaceText` 图标，hover 时才染 `primary`。中间那个不做特殊高亮——它和两侧
只是功能不同，不是层级不同，三种颜色摆在一起会被读成两类控件。

### 0.0 弹窗的结构：三栏工作室（照 depth_wallpaper_studio 原型）

原型是一个全屏三栏工作台：画廊 240 | 舞台 | 检查器 328。弹窗按同一构图实现，
卡片 1480×920（小屏退化为旧对话框尺寸）：

```
┌────────────────────────────────────────────────────────────────────────┐
│ [◆] DEPTHSCAPE 工作室 │ 个性化 / 背景效果 │                               [×] │ 70px
├──────────┬──────────────────────────────────────────┬──────────────────┤
│ OUTPUT   │  DP-1  OUTPUT     ┌────────┬────────┐    │ PERSONALIZE      │
│ 输出与预览│  壁纸组件实时合成…  │        │        │    │ 个性化编辑        │
│ ┌──────┐ │                   │ 预览    │        │    │ ┌景深┬视差┬组件┬参┐│
│ │缩略图││ │                   │ 16:9   │        │    │ │              │ │
│ │DP-1  ││ │                   │        │        │    │ │ 分组 + 控件    │ │
│ └──────┘ │                   └────────┴────────┘    │ │ + 说明块      │ │
│ ┌──────┐ │  实时预览·图层合成          2560 × 1440     │ │              │ │
│ │DP-3  ││  [⊞重新映射] [⊞辅助线] ● 就绪              │ │              │ │
│ └──────┘ │                                          │ │              │ │
│           │                                          │ │              │ │
└──────────┴──────────────────────────────────────────┴──────────────────┘
```

* **画廊 = 输出**。每块输出一张 16:9 **实况缩略图**（那块屏此刻的壁纸 +
  组件 + 遮罩），点卡片切换 stage。画廊提供本地壁纸选择，不会改写组件布局。
* **stage**：完整 16:9 实况。右上「遮罩 / 原图」分段切换（原型是纯净/桌面/窗口），
  工具行第三颗是「构图辅助线」（三分线，只作用于预览）。
* **检查器**：背景效果 / 组件两种属性页。壁纸选择和切换集中在左侧画廊；背景页只放视差、空间壁纸和**景深遮罩**区块——遮罩是壁纸派生的 modifier，不是图层；效果关闭时整个遮罩区块隐藏。时钟的字体预设渲染成原型那种
  2×2 风格卡片（样张用各自的真实字体），颜色渲染成色板条；其余 schema 键走
  细轨滑杆 / 开关 / 内联下拉。
* **图层列表**：只有两类真实图层——`背景底图`（锁定在底部）和 `组件`。组件行支持双击重命名、眼睛显隐、`遮挡/置顶`开关和拖拽排序；列表按 Photoshop 习惯把最上层放在最上面。遮罩不占图层行，它作用于所有 `occlude != false` 的组件。
* 配色 / 字号 / 圆角 / 栏宽集中在 `DepthStudioTokens.js`。

### 0.1 按钮的状态机

三个按钮是同一个组件 `qml/widgets/DepthIconButton.qml` 的实例。写它是因为
"把中间那个做得和两侧一样"这句话必须改三个地方；一个组件只有一处答案。

| 状态 | 触发 | 视觉 |
| --- | --- | --- |
| Default | — | 基准表面 + `outlineMedium` 描边 |
| Hover | 指针进入 | **图标放大到 1.12**，8% state layer 提亮表面，描边升到 `outline`，接触阴影变大 |
| Pressed | 按住未松 | **背景加深**（黑色 26% 覆盖层）+ 整体缩到 0.97 + 阴影收拢 |
| Focus-visible | Tab 聚焦 | 圆外 2px `primary` 焦点环；Space/Enter 可激活 |
| Disabled | `available: false` | 卡片保持不透明、图标对比度降到 38%、无阴影、`not-allowed` 光标 |
| Loading | 异步进行中 | 图标换成 spinner、禁止重复点击、直径不变（行不抖） |
| Checked | toggle 型 | 表面与图标染 `primary` |

两条容易做错的：

* **Disabled 用 `available` 而不是 `enabled`**。Qt 会把 `enabled: false`
  传染给子项，`HoverHandler` 跟着死掉，`not-allowed` 光标就没机会出现了。
* **Disabled 降的是图标对比度，不是整块透明度**。整块淡出会让底下的壁纸透
  上来——红桌面上的禁用按钮会变成红的，看着像"另一种按钮"而不是"不能用"。

**弹窗的关闭方式**：只有 `Esc` 与右上角 `×`。scrim 不再响应点击——它盖住整个输出，
一次误点就把设置关了，实测两次都发生在拖滑杆的中途。scrim 只负责挡输入，不负责关闭。

`stateOverride` 是这个组件专门留的钩子（0=实时 / 1=hover / 2=pressed）：QML
无法移动指针，没有它，Hover 和 Pressed 会是这七个状态里唯一两个上线前从没被
渲染过的。验证方式就是七个状态并排抓一张图：

![七个状态的并排抓图](plugin-list-buttons-states.png)

> 预览的圆角**不能**用 `Rectangle { clip: true; radius: … }`。Qt 的 `clip`
> 是对包围盒的剪裁，完全不看 `radius`，结果是圆角背景里贴着一张直角壁纸。
> 用 `Quickshell.Widgets` 的 `ClippingRectangle`（DMS 的 `DankCircularImage`
> 就是它），子项走 shader 剪裁，四角才真的是圆角。

> 实现上有个坑值得记一笔：这三个按钮的显示/隐藏**不能**绑在 MouseArea 的
> `containsMouse` 上。MouseArea 的 hover 是独占的——指针一移到按钮自己的
> MouseArea 上，底下那个就报 `containsMouse == false`，按钮会在鼠标够到它的
> 那一刻消失。所以 hover 用 `HoverHandler`（被动，不会因为子项而被抢走），
> 点击用 `TapHandler`（不参与 hover 竞争）。

> 为什么预览要能切显示器：壁纸、遮罩、调色板都是**逐输出**的，两个屏幕
> 常常是两张不同的图。只预览第一块屏，等于对第二块屏撒谎。

**设置弹窗**（点 `⚙` 打开）
浮在桌面之上的一层 overlay，居中卡片、点外部或按 Esc 关闭。内容是本文档
下面列出的全部选项：景深效果、background widget 编辑器、IPC 命令、使用
指南、关于。它和原来的内联设置页是**同一个组件**
（`qml/DepthSettingsPane.qml`），只是换了个宿主。

弹窗开在你当前聚焦的显示器上；它内部的预览则跟着你在内联面板里选中的
那个输出走。

也可以不开界面直接调出来：

```bash
dms ipc call depthscape settings     # 切换开关
```

绑到 compositor 快捷键上即可当"设置面板"用。

---

## 1. 景深效果（Depth effect）

插件的核心行为：在壁纸近景遮住 background widget 的地方把它们擦除，让主体
出现在 widget 之前。壁纸本身永远不被修改。

### 遮挡遮罩（Occlusion mask）

面向用户的算法只有两个滑杆；它们上游的一切都是固定的——这正是结果可预期的原因。

| 键           | 界面标签                 | 默认   | 范围      | 作用                                         |
| ----------- | -------------------- | ---- | ------- | ------------------------------------------ |
| `threshold` | Foreground Threshold | `30` | 0–100 % | 深度截断点。调低让更多场景出现在 widget 之前；调高则只保留最靠近相机的部分。 |
| `feather`   | Edge Feather         | `8`  | 0–50 %  | 截断边缘的软过渡宽度。`0` 是完全二值的硬遮罩；调大则擦除边缘逐渐融合、变柔。   |

### 画布跟随工作区

| 键                 | 界面标签              | 默认     | 范围  | 作用                                                |
| ----------------- | ----------------- | ------ | --- | ------------------------------------------------- |
| `parallaxEnabled_<屏幕>` | Workspace translation parallax | `true` | 开关  | 切换工作区时，让该输出的场景——壁纸、遮罩与 widget——滑过一小段屏幕。与空间壁纸互斥。 |
| `spatialEnabled_<屏幕>` | Spatial wallpaper | `false` | 开关  | 生成深度网格、前景遮罩、近景影响图与背景补洞贴图；鼠标移动驱动相机视角。与工作区平移视差互斥。构建 Quick3D 插件后使用完整深度网格；未构建时退回分层着色器。 |
| `spatialTravel_<屏幕>` | Spatial motion | `3` | 1–8 % | 鼠标驱动相机运动的强度：1% 约为 0.4° 水平 / 0.3° 垂直，默认 3% 约为 1.2° / 0.9°。启用空间壁纸时会为当前显示器准备图层。 |

全部事件驱动：插件只响应合成器的工作区事件，从不轮询。

## 2. 深度模型（Depth model）

| 键           | 界面标签          | 默认      | 作用                                                                                                                  |
| ----------- | ------------- | ------- | ------------------------------------------------------------------------------------------------------------------- |
| `modelType` | Model Variant | `small` | 运行哪个 Depth Anything V2 检查点：`small`（约 99 MB，快）、`base`（约 389 MB，均衡）、`large`（约 1.34 GB，高质量）。变体在首次使用时下载到插件数据目录，并做校验和验证。 |

同一卡片里的按钮：

* **Install / Verify Model** — 重新下载并校验所选变体。
重新分析可通过 IPC 命令触发；设置界面不提供手动重分析按钮。

状态芯片显示所选模型是已安装、下载中，还是等待首次使用。

## 3. Background widgets

Background widget 是 Depthscape 自己的 widget 层——位于 DMS 桌面 widget 之下的
一个平面，被景深效果遮罩。设置页的图层列表和 `widgets.json` 编辑的是同一份数据：

```json
{
  "widgets": [
    {
      "id": "clock-main",
      "type": "depthscape.clock",
      "x": 120,
      "y": 140,
      "screen": "DP-3",
      "settings": { "showSeconds": true }
    }
  ]
}
```

* `id` — 每条唯一；设置页通过它定位 widget。
* `type` — **已注册**的类型 id。未注册的类型不渲染任何东西。
* `name` — 可选。图层显示名；省略时用类型注册名，同类型第二个实例会自动加序号。
* `x`、`y` — 距输出左上角的逻辑像素。移动 widget 就改这里。
* `screen` — 可选；把 widget 限定在某一块显示器上。
* `visible` — 可选；`false` 隐藏该实例（设置页仍保留这一行）。
* `occlude` — 可选；`false` 表示不参与景深遮挡，始终绘制在遮罩之上（图层列表里显示为 `置顶`）。
* `pinned` — 可选；`true` 把组件固定在屏幕上（不随视差效果移动），但遮罩仍随壁纸移动，所以主体经过时仍会擦除它。固定时 `occlude` 不生效，始终参与遮挡。
* `settings` — 逐实例覆盖，浅合并**在**该类型注册的默认值**之上**。
* **数组顺序就是绘制顺序**（越靠后越靠上）。图层列表反向显示为“最上层在最上面”，拖拽会改写数组顺序。

**Write Example Layout** 按钮会写入一份起始布局（会覆盖现有文件——先备份你
的修改）。

### 编辑已摆放的 widget

**图层列表**是主入口：拖动行改变绘制顺序；双击名字重命名；眼睛图标切换
`visible`；右侧 `遮挡/置顶` 徽章切换 `occlude`；pin 图标切换 `pinned`。
`置顶` 的组件不参与景深擦除，始终画在遮罩之上；`pinned` 的组件固定在屏幕上，
但仍会被随壁纸移动的遮罩擦除。

**Background Widgets** 区为每条 widget 提供一个编辑器：

* **Position X / Y** — 覆盖所有已连接屏幕逻辑尺寸的滑杆。滚轮只会滚动页面，
  不会改变数值。
* **样式项** — 按 widget 类型注册的 `configSchema` 自动渲染：数字是滑杆、
  布尔是开关、颜色是拾色板色块（点击可打开 DMS 拾色板弹窗，支持透明度棋盘格预览）加十六进制输入框、文本是输入框，`select` 与字体
  则是下拉框。
* **Remove** — 删除这条。没有撤销；该文件就是普通 JSON。

**Reset 语义。** 重置会把该键的覆盖从布局文件中**删除**——类型的注册默认值
随之透出，与一条从未写过这个键的 widget 完全同路。reset 出现在 number、
colour、text 行上，且仅当它们与默认不同；布尔和下拉永远不出 reset——没有
覆盖时它们显示的本来就是默认值。

### 添加 widget

**Add** 行列出所有已注册的 background widget 类型——Depthscape 自己的和
其他插件贡献的一视同仁。新 widget 从 `200, 200` 开始。

---

## 4. 时钟（`depthscape.clock`）

Depthscape 自带、也是注册 API 参考实现的时钟 widget 类型，走手机锁屏的心智
模型：大号比例无衬线数字，可选的右上角小秒角标、底部对齐的 AM/PM 角标，
下方一行安静的日期。以下全部可以逐实例设置。

### 字体

| 键 | 默认 | 作用 |
| --- | --- | --- |
| `fontPreset` | `"misans"` | **风格预设**，不是字体品牌：`theme` / `misans` / `inter` / `modern-bold` / `minimal-thin` / `digital-tech` / `magazine-serif` / `custom`。每个预设按候选列表匹配系统已安装的字体，且**链尾一定是一个真实存在的字体**（Inter / Noto Sans / Georgia / Maple Mono），所以没装首选字体时会降级到同气质的一款，而不是掉回主题字体——开发者机器上的主题字体常常是等宽编程字体，掉回去看起来就像插件坏了。旧的 `poppins` / `roboto` 自动映射到 `inter`。 |
| `fontFamily` | `""` | 只有当 `fontPreset` 为 `custom` 时生效。空 = 主题字体。 |
| `weight` | `"auto"` | `auto` 跟随预设自带的字重（`modern-bold` → Bold，`minimal-thin` → Light，`digital-tech` → SemiBold，`magazine-serif` → Medium）；显式指定则覆盖它。`Medium` 接近 HyperOS 锁屏默认；`Light` 更接近 ColorOS。 |

四个风格预设对应的字体（装了就自动用，没装按链降级）：

| 预设 | 首选 | 兜底链 | 气质 |
| --- | --- | --- | --- |
| `modern-bold` | Space Grotesk | Archivo → Manrope → Inter | 宽体几何怪诞，字重压得住大字号 |
| `minimal-thin` | Jost | Manrope → Inter → Noto Sans | Futura 一脉的几何细体，字腔大、克制 |
| `digital-tech` | Rajdhani SemiBold | Rajdhani Medium → Rajdhani → Chakra Petch → Maple Mono | 方正半窄，仪表盘/科幻感 |
| `magazine-serif` | Playfair Display | IBM Plex Serif → Georgia → Noto Serif | 高对比衬线，时尚杂志封面 |

`misans` 的候选顺序：`MiSans` → `MiSans VF` → `MiSans Latin` → `MiSans Dev`
→ `HarmonyOS Sans SC` → `HarmonyOS Sans` → `Inter` → `Noto Sans`。

字体需要你自己装（插件不打包，体积和许可都不合适）。装到
`~/.local/share/fonts/` 后 `fc-cache -f` 即可被识别。

### 尺寸与显示

| 键 | 默认 | 范围 | 作用 |
| --- | --- | --- | --- |
| `timeSize` | `160` | 40–480 px | 时间文字高度。秒角标 = 22%、AM/PM 角标 = 22%、日期行 = 14%，全部由它派生。 |
| `use24Hour` | `true` | 开关 | 关闭切换到 12 小时制并显示 AM/PM 角标（角标底部对齐到时间基线）。 |
| `showSeconds` | `false` | 开关 | 打开后在时间右侧加一个小号秒角标，位于时间的大写高度线上（superscript 视觉感）。 |
| `showDate` | `true` | 开关 | 时间下方一行日期。 |
| `dateFormat` | `"dddd, MMMM d"` | 文本 | Qt 日期格式串。 |
| `layout` | `"horizontal"` | `horizontal` / `stacked` | `horizontal` 时间一行（HyperOS 默认）；`stacked` 小时在上、分钟在下（ColorOS / OriginOS 的竖排锁屏）。竖排会让整块高度翻倍，通常要同时下调 `y` 或 `timeSize`，否则会顶到屏幕边缘。 |
| `align` | `"left"` | `left` / `center` / `right` | 日期行相对数字的对齐方式，以及竖排时两行的对齐边。只作用于 widget 盒子内部；盒子本身在屏幕上的位置由下面的锚点决定。 |

### 颜色

| 键 | 默认 | 范围 | 作用 |
| --- | --- | --- | --- |
| `colorMode` | `"auto"` | 选项 | `auto` 按**时钟背后局部区域**的相对亮度，选出对比度最高的中性色（亮区深字、暗区浅字），点缀色只在自身也够对比时才采用；`theme` 让主时间承载壁纸主题色（够可读时），把染色感拉满；`custom` 用下面的手动颜色。全部遵循 WCAG 对比度（≥3:1，大号文字）。 |
| `color` | `"#f8f9fa"` | 颜色 | 仅 `custom` 生效。主时间颜色，秒 / AM-PM 角标跟随它。 |
| `dateColor` | `"#f8f9faA6"` | 颜色 | 仅 `custom` 生效。日期行颜色，默认带 alpha 作次级。 |

`auto` / `theme` 的判定链路：Rust 在生成遮罩的同一次采图里，除了产出整张图的
调色板 sidecar（`cache/palettes/<hash>-p2.json`，含 `text`/`accent`/`secondary`
和一张 **16×16 相对亮度网格**），host 再按每个 widget 的屏幕矩形去网格上采样它
**正后方**的局部亮度（`localLuma`），交给 [DepthAutoColor.js](../qml/DepthAutoColor.js)
用 WCAG 公式（相对亮度线性化 + `(L1+0.05)/(L2+0.05)`）挑色。因此"上亮下暗"的壁纸，
上半的时钟会挑深字、下半会挑浅字——这正是"只用整张平均色"会做错的情形。局部太花、
连白/黑都达不到 3:1 时，自动开 `scrim` 兜底。sidecar 缺失（首帧/损坏）时回落到手动色。

### Scrim（压暗底衬）

| 键 | 默认 | 范围 | 作用 |
| --- | --- | --- | --- |
| `scrim` | `false` | 开关 | 在文字下方画一层半透明深色板，独立于颜色模式。这才是手机锁屏在亮壁纸上保证可读性的真实手段——Qt 的 `Text.Outline` 字形描边宽度固定约 1px，在这种大字上几乎不可见，因此不提供。 |
| `scrimColor` | `"#00000066"` | 颜色 | Scrim 填充色，默认 40% alpha 的黑。 |
| `scrimPadding` | `0.18` | 0–1 | Scrim 相对文字的外扩，按 `timeSize` 比例，会随字号缩放。 |
| `scrimRadius` | `0.16` | 0–2 | Scrim 圆角，同样按 `timeSize` 比例。 |

开启 `scrim` 时，widget 的实际尺寸会在文字块四周加上 `2 × scrimPadding`，
所以遮罩擦除区域和视差位移都按扩大后的盒子计算，不会让底衬被裁切。

### 数字宽度稳定性

当前 Qt 6.12 的 `Text` 类型没有暴露 OpenType feature 相关 API（`fontFeatureSettings` /
`QFont::setFeature` 均无），所以不能靠 `'tnum' on` 强制 tabular figures。锁屏风格时钟
依赖所选字体本身的数字宽度：MiSans / Inter / Roboto / Poppins 等现代无衬线数字
本身就非常接近等宽，跳动幅度肉眼几乎看不出。如果这对你确实干扰视觉，下一步可以
用 `TextMetrics` 手工把 `timeMain.implicitWidth` 钉到 "00:00" 的实测宽度（原 LCD 版
本用同样的方法处理日期行的居中），这个改动很小。

### 位置（position）

位置**刻意不属于** `settings`：`x` / `y` 是所有 widget 类型共享的布局属性，
这样"它在哪"只有一个答案。它们同样可以在 Background Widgets 区调整，
也可以改布局文件。

`anchorX`（`left` / `center` / `right`）和 `anchorY`（`top` / `center` / `bottom`）
同样是布局属性，默认 `left` / `top`，也就是原来的"左上角坐标"语义。设成
`center` 后，`x` / `y` 表示 widget 的中心点——**这是时钟能一直居中的关键**：
字号一改，widget 宽度就变，左上角坐标会随之漂移，中心点不会。竖排 + 居中
的锁屏组合通常写成：

```json
{ "x": 1280, "y": 470, "anchorX": "center", "anchorY": "center" }
```

---

## 5. 杂志风文字标语（`depthscape.motto`）

Depthscape 自带的杂志大字排印组件，适合将极具视觉张力的标题或格言沉浸在壁纸主体身后。

| 键               | 默认                  | 范围       | 作用                                               |
| ---------------- | --------------------- | ---------- | -------------------------------------------------- |
| `text`           | `"CREATIVE FREEDOM"`  | 文本       | 主标题文字内容。                                   |
| `subtitle`       | `"ISSUE 01 // VOL 26"`| 文本       | 标题上方的小副标或期号行，留空隐藏。               |
| `fontFamily`     | `""`                  | 字体       | 字体族。空 = 主题字体。                            |
| `fontSize`       | `120`                 | 32–320 px  | 主标题字号。副标题按比例缩放。                     |
| `letterSpacing`  | `4`                   | −5–40 px   | 字间距（字距微调）。                               |
| `fontWeight`     | `"Black"`             | 选项       | 字重：`Normal`、`Medium`、`DemiBold`、`Bold`、`ExtraBold`、`Black`。 |
| `uppercase`      | `true`                | 开关       | 转为全大写，符合现代杂志标题风格。                 |
| `italic`         | `false`               | 开关       | 斜体。                                             |
| `color`          | `"#ffffff"`           | 颜色       | 主标题文字颜色（支持拾色板）。                     |
| `subtitleColor`  | `"#ffffff99"`         | 颜色       | 副标题颜色（默认带透明度）。                       |
| `opacity`        | `0.90`                | 0–1        | 整体不透明度。                                     |
| `outline`        | `true`                | 开关       | 是否加描边，确保在亮色壁纸上清晰可读。               |
| `outlineColor`   | `"#000000"`           | 颜色       | 描边颜色。                                         |

---

## 6. 极简月历（`depthscape.calendar`）

Depthscape 自带的极简月历组件，以无背景卡片的网格呈现当月日期，当天自动高亮。

| 键               | 默认          | 范围  | 作用                                             |
| ---------------- | ------------- | ----- | ------------------------------------------------ |
| `monthFormat`    | `"MMMM yyyy"` | 选项  | 月份/年份标题格式（`MMMM yyyy`、`MMM yyyy`、`yyyy.MM`、`none` 隐藏）。 |
| `weekStart`      | `"Monday"`    | 选项  | 每周起始日（`Monday` 周一、`Sunday` 周日）。     |
| `fontFamily`     | `""`          | 字体  | 字体族。空 = 主题字体。                          |
| `cellSize`       | `36`          | 20–80 px | 每天单元格宽高。                              |
| `cellSpacing`    | `4`           | 0–20 px  | 单元格之间的间距。                            |
| `color`          | `"#f4f4f8"`   | 颜色  | 常规日期数字颜色。                               |
| `accentColor`    | `"#3a86ff"`   | 颜色  | 当天（Today）高亮圆圈背景色。                    |
| `dimColor`       | `"#ffffff40"` | 颜色  | 星期标头行（Mo Tu We...）颜色。                  |
| `showWeekdays`   | `true`        | 开关  | 是否显示星期标头行。                             |
| `highlightToday` | `true`        | 开关  | 是否在当天数字下方绘制圆形高亮底色。             |
| `outline`        | `true`        | 开关  | 数字描边，保障明亮壁纸对比度。                   |
| `outlineColor`   | `"#000000"`   | 颜色  | 描边颜色。                                       |

---

## 7. IPC

| 命令                                      | 作用                                 |
| --------------------------------------- | ---------------------------------- |
| `dms ipc call depthscape generate`      | 在所有输出上重新生成遮罩。                      |
| `dms ipc call depthscape install small` | 下载并校验深度模型（`small`、`base`、`large`）。 |
| `dms ipc call depthscape clearCache`    | 清除深度、精化场与遮罩的缓存。                    |
| `dms ipc call depthscape remap`         | 在所有输出上重新映射两个表面。                    |
| `dms ipc call depthscape settings`      | 切换独立设置弹窗（见第 0 节）。                  |
| `dms ipc call depthscape debugMode on`  | 本次 shell 会话中显示空间幅度、阈值、羽化和遮罩对齐调试项。 |
| `dms ipc call depthscape debugMode off` | 隐藏调试项，并让遮罩对齐恢复默认值（0, 0, 100%）。 |
| `dms ipc call depthscape debug`         | 守护进程状态、遮罩路径、已注册的 widget 类型与合成器规则自检结果。 |

### Niri 共享背景规则

Depthscape 的 wallpaper、widget 和 foreground surface 位于 Niri 的 `background`
layer，并通过 `place-within-backdrop` 规则共享一块背景：

```kdl
layer-rule {
    match namespace="^depthscape:"
    place-within-backdrop true
}
```

启动自检会跟随 Niri 配置的 `include`，并在 `debug` 的 `niriLayerRule` 中报告
`ok`、`partial`、`missing` 或 `unknown`。

空间壁纸在桌面空白区域跟随鼠标。输入使用单独的透明 surface，命名空间为
`depthscape-spatial-input`，不要将它放入 backdrop；指针进入应用窗口时，
场景保持最后的位置。该 surface 会转发 DMS 的桌面右键菜单操作。
