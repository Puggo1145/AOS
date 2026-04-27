# OS Sense 设计

## 目标

让 agent 实时感知用户当前的可引用 OS 状态：在使用什么 app、看什么窗口、选了什么、在哪打字。该状态以**实时镜像**的形式存在于 Shell 进程中，Notch UI 直接绑定，永远是当前真相。

剪贴板与视觉截图**不是** live mirror 字段：剪贴板由 Shell composer 在用户粘贴 gesture 时一次性捕获（见 §"Clipboard capture"）；视觉截图由 Shell 在用户提交时 on-demand 单帧捕获（见 §"ScreenMirror（视觉兜底）"）。两者都属于 Shell composer 的 submit-path 责任，OS Sense 不监听 copy 事件，也不维护视觉的 live state。

非目标：

- 任何形式的历史 / 回放
- 鼠标轨迹 / 键盘事件流采集（不申请 Input Monitoring）
- 跨 app attention transition 分析、相关性排序
- live mirror 内的主动 snapshot（live mirror 仅由 OS 事件源驱动；submit-time 视觉与 paste-time 剪贴板的捕获是 Shell composer 的事，不属于 live mirror）
- 缓存对象（不存在"取一次值再复用"）

## 核心范式：live state mirror

`SenseStore` 是 Shell 进程内的长生命周期 actor，订阅 OS 事件源，把当前 OS 状态实时同步到一个 `@Observable` 的 `SenseContext` 上。Notch UI（折叠态与展开态）直接绑定，OS 状态变化即 UI 变化。

Notch 打开只是 UI 视图切换，不触发任何数据采集。用户在展开态勾选 chip 并提交时，Shell 把勾选条目组装成 `citedContext` 发给 Bun。未勾选条目永远不离开 Shell 进程。

## 设计原则

1. **Public schema 完全 general**——`SenseContext` 顶层字段不出现任何 app-specific 概念
2. **Specific 信息走插件**——通过 `Behavior` 协议下沉到 adapter 自己定义的类型里
3. **Behavior 是 opaque payload**——SenseStore / RPC / 默认 UI 全程透传，不读字段；只有 LLM 在 prompt 里消费具体结构
4. **失败隔离**——任一 adapter 失败不影响 General Probe 与其他 adapter
5. **共享 AX 底座**——任何组件**为接收 AX 通知**而订阅时必须通过 `AXObserverHub`，由 hub 统一管理 observer 生命周期、跨进程消息分发、retain 关系。**已知例外**：`AOSComputerUseKit` 在 Chromium / Electron app 首次 snapshot 时会**自起 AXObserver** 挂在 Shell main runloop（callback 为 no-op）。该 observer 不消费通知，仅以"存在性"向 Chromium 发信号让其保持 web AX tree 开启，与 hub 的"接收并分发通知"职责正交，复用 hub 反而扭曲两者语义；故允许这一例外，但要求 Computer Use 自管该 observer 的 retain / 释放（详见 `designs/computer-use.md` Chromium AX 激活段），不得用于真实 AX 通知消费。
6. **共享 AX SPI 底层模块**——`_AXUIElementGetWindow` 等 macOS 私有 AX SPI 的 `@_silgen_name` 桥接归属于独立的 `AOSAXSupport` Swift package，OS Sense Core 与 `AOSComputerUseKit` 都依赖它。**禁止 `AOSOSSenseKit` 依赖 `AOSComputerUseKit`**（读侧不得依赖写侧），任何 SPI 复用必须经由 `AOSAXSupport` 下沉。
7. **共享权限服务**——Accessibility / Screen Recording / Automation 的运行时探测由 Shell 级 `PermissionsService` 统一负责，OS Sense / Computer Use / 权限引导 UI 全部读同一份 `PermissionState`，不得在模块内自起探测路径。

## SenseContext 数据结构

```swift
struct SenseContext {
    let app: AppIdentity              // NSWorkspace 原语
    let window: WindowIdentity?       // AX 原语
    let behaviors: [BehaviorEnvelope] // 异质，由 GeneralProbe + 各 adapter 共同填充
    let permissions: PermissionState
}

// `VisualMirror` 与 `ClipboardItem` 都**不是** SenseContext 的字段：
//
// - 视觉兜底是 submit-time on-demand 截图（见 §"ScreenMirror（视觉兜底）"），
//   由 Shell 在用户提交时调用 `SenseStore.captureVisualSnapshot()` 单帧捕获。
// - 剪贴板退出 OS Sense 的 live mirror（见 §"Clipboard capture"）：Shell
//   composer 在用户**真正粘贴**到输入框时一次性快照 pasteboard，作为下一次
//   提交的 `clipboard` 参数传给 `CitedContextProjection`。OS Sense 不维护
//   剪贴板的 live state，也不轮询 pasteboard。

struct AppIdentity {
    let bundleId: String
    let name: String
    let pid: pid_t
    let icon: NSImage
}

struct WindowIdentity {
    let title: String
    let windowId: CGWindowID?   // 通过 _AXUIElementGetWindow 取；degraded 模式（无 AX 权限）下为 nil
}

struct SelectedItem {
    let role: String
    let label: String
    let identifier: String?
}

// `ClipboardItem` 仍住在 OS Sense 包内（pasteboard 抽取规则与 wire 投影
// 都属于 OS Sense 契约），但**不在 SenseContext 上**。Shell composer 在
// 粘贴瞬间通过 `ClipboardPasteboardExtractor.extract(from:)` 把
// `NSPasteboard` 投成 `ClipboardItem`，作为 per-turn 状态持有。
enum ClipboardItem {
    case text(String)
    case filePaths([URL])
    case image(metadata: ImageMetadata)   // {width, height, type}，无像素
}

struct VisualMirror {
    let latestFrame: CGImage              // 内存中最新一帧；引用时再 PNG 编码
    let frameSize: CGSize
    let capturedAt: Date
}

struct PermissionState {
    let denied: Set<Permission>
}

enum Permission { case accessibility, screenRecording, automation }
```

## Behavior 契约

跨进程数据边界是 `BehaviorEnvelope`，结构固定。具体的 Swift Behavior 类型只存在于 producer（GeneralProbe 或某个 Adapter）内部，由 producer 自行映射成 envelope；core 与下游永不感知 producer 类型。

```swift
struct BehaviorEnvelope: Codable, Sendable, Identifiable {
    let kind: String              // 跨进程鉴别符，e.g. "general.selectedText"
    let citationKey: String       // 引用稳定 ID
    let displaySummary: String    // 默认 chip 渲染用
    let payload: JSONValue        // opaque payload，结构由 kind 约定
    var id: String { citationKey }
}
```

`SenseStore` / RPC / 默认 UI 全程透传 envelope，不读 `payload`。只有 LLM 在 prompt 里按 `kind` 解读 payload 结构。

### Built-in kinds（GeneralProbe 输出）

producer 内部可保留强类型 struct，最后一步映射为 envelope。

| kind | payload schema | 采集源 | 识别条件 |
|---|---|---|---|
| `general.selectedText` | `{ content: String }` | `AXSelectedText` | 属性存在且非空 |
| `general.selectedItems` | `{ items: SelectedItem[] }` | `AXSelectedChildren` / `AXSelectedRows` | 数组非空 |
| `general.currentInput` | `{ value: String }` | `AXFocusedUIElement` 的 `AXValue` | 元素可编辑且 value 非空 |

**去重**：`general.selectedText` 与 `general.currentInput` 来自同一元素时只保留前者。

**逐字捕获，1 MiB 兜底**：所有文本（`selectedText`、`currentInput`、剪贴板）都按"用户的显式信号必须完整给模型"原则**逐字**进入 payload，没有内容感知的截断（不按 token、句子、段落裁）。`PayloadSizeGuard.clamp` 在单个字符串超过 1 MiB UTF-8 字节时做 defense-in-depth 兜底裁剪并附 `…[truncated, original N bytes]` 标记，避免一次失控捕获把 NDJSON 帧撑破——但这条 cap 在任何现实人类内容下都不会触发，业务语义上仍然按"不截断"对待。

chip 表面只显示固定 label（`Selected text` / `Current input`），不暴露内容前缀——signal 是
"用户选了/输入了什么类型的东西"，内容由 LLM 读 payload。

**`general.selectedItems` 不递归**：只返直接选中那一层。

## 架构总览

```
┌────────────────────────────────────────────────────────────────┐
│ SenseStore (@MainActor @Observable final class)                 │
│   持有当前 SenseContext，向 UI 推送变更                          │
│                                                                  │
│   ├── WindowMirror      ← NSWorkspace + AXObserverHub            │
│   ├── GeneralProbe      ← AXObserverHub                         │
│   ├── ScreenMirror      ← SCScreenshotManager (submit-time)      │
│   └── AdapterRegistry   ← 已注册的 SenseAdapter 实例             │
│           ├── FinderAdapter                                       │
│           └── BrowserAdapter                                      │
└────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                  AXObserverHub（共享底座）
                  封装 AXObserver 生命周期 / 跨进程消息分发
```

`SenseStore` 是唯一持有 `SenseContext` 的对象，所有写入经它的串行化入口，确保单源真相。

## 事件源与字段映射

| 事件 | API | 维护字段 | 频率控制 |
|---|---|---|---|
| 前台 app 切换 | `NSWorkspace.didActivateApplicationNotification` | `app` / 重建 AX 订阅 / 重新路由 adapter | 无 |
| 焦点窗口切换 | `kAXFocusedWindowChangedNotification` | `window.title` | 无 |
| 焦点元素切换 | `kAXFocusedUIElementChangedNotification` | currentInput 目标 | 无 |
| 选中文本变化 | `kAXSelectedTextChangedNotification` | `general.selectedText` | 50ms debounce |
| 选中条目变化 | `kAXSelectedChildrenChangedNotification` / `kAXSelectedRowsChangedNotification` | `general.selectedItems` | 50ms debounce |
| 输入框内容变化 | `kAXValueChangedNotification` | `general.currentInput` | 250ms debounce |
| 视觉兜底 | `SCScreenshotManager` 单次捕获 | 提交时 `captureVisualSnapshot()` 返回值 | 仅在用户点 send 时执行一次 |

**剪贴板不在表内**：见 §"Clipboard capture"。OS Sense 不订阅 pasteboard
变化，剪贴板由 Shell composer 在用户粘贴瞬间一次性捕获。

debounce 在 `SenseStore` 写入入口执行。

## SenseAdapter 协议

Adapter 是 app-specific 能力的唯一承载形式。

```swift
protocol SenseAdapter: Actor {
    static var id: AdapterID { get }
    static var supportedBundleIds: Set<String> { get }
    var requiredPermissions: Set<Permission> { get }   // attach 阶段必需

    /// supportedBundleIds 内的 app 进入前台时调用。
    /// adapter 通过 hub 订阅 AX 通知，emit 当前完整的 envelope 集合。
    func attach(hub: AXObserverHub, target: RunningApp) -> AsyncStream<[BehaviorEnvelope]>

    /// app 离开前台时调用，adapter 释放所有订阅。
    func detach() async
}
```

每次 emit = 该 adapter 当前完整的 envelope 集合。`SenseStore` 按 adapter ID 整体替换。

**注册**：app 启动时 `AdapterRegistry` 收集所有内置 adapter；前台 app 切换时按 `supportedBundleIds` 路由。同一 app 可被多个 adapter 命中，按注册顺序串行 attach。

**失败隔离**：adapter 调用包在 timeout（500ms 上限）+ try/catch。失败让该 adapter 输出空 behavior 集合，不影响其他来源。

**权限隔离**：`requiredPermissions` 仅指 attach 阶段必需的权限，缺失则该 adapter 跳过 attach。权限状态由 `PermissionsService` 持有并发布，`SenseStore.permissions` 由 service 投影；`AdapterRegistry` 在跳过 attach 时只通知 service，不直接写 `permissions.denied`。`SenseStore` 在 `PermissionState.denied` 集合实际变化时会重跑 swap 链路，所以 grant→attach 与 revoke→detach 双向都自动闭环（GeneralProbe / WindowMirror 走专属 `.accessibility` 分支，与 adapter 路径解耦）。

**AX 消费 adapter 必须声明 `.accessibility`**：任何通过 `AXObserverHub` 订阅 `kAX*` 通知的 adapter 都 MUST 把 `.accessibility` 加进 `requiredPermissions`。hub 只做路由不做授权——`AXObserverCreate` 在 Accessibility denied 时静默失败，hub 拿到 nil token，但 `attach()` 仍会成功返回一条空 stream，于是 chip 槽位会被一个不出 signal 的"空壳 adapter"占住。把 `.accessibility` 写进 `requiredPermissions` 才能让 revoke 时 swap 链路真正把 adapter 拉下来，恢复 degraded 模式契约。

**Lazy enrichment 权限**：adapter 在 attach 之后通过 chip 操作触发的额外权限（如 Apple Event）不属于 `requiredPermissions`。adapter 只负责**触发** enrichment 动作（执行 Apple Event 等会触发系统授权 prompt 的调用）并把授权结果**回报给 `PermissionsService`**；权限状态的发布由 service 统一负责，`SenseContext.permissions` 由 service 投影。Adapter 不直接读写 `permissions.denied`。未授予时对应 envelope 字段缺省，chip 仍存在以便用户主动点击触发授权。

**依赖方向（核心契约）**：

- Core 模块（`SenseStore` / `BehaviorEnvelope` / `GeneralProbe` / `ScreenMirror` / `ClipboardPasteboardExtractor` / `AdapterRegistry` / `SenseAdapter` 协议）**不得 import 任何具体 adapter 类型，也不得感知 adapter 内部的 Behavior struct**。core 只见 `[BehaviorEnvelope]` 流与 `SenseAdapter` 协议
- 具体 adapter（`FinderAdapter` / `BrowserAdapter` / 未来扩展）**只能 import core**，不得反向被 core 引用
- Adapter 注册由 Shell composition root 完成；新增 adapter 不应改动 core 任一文件
- 任何让 core 出现 specific 分支或类型分发的 PR 都视为破坏架构边界

**其他契约**：

- Adapter 不能影响 GeneralProbe 输出与去重 / 截断规则
- Adapter 不能持有 `SenseStore` 引用、不能跨 adapter 通信
- Adapter 不能自起 `AXObserver` / 后台线程 / 定时器之外的资源

## 内置 Adapter

### FinderAdapter

emits `kind = "finder.selection"`，payload schema：

```ts
{
    items: SelectedItem[],
    fileURLs: { [identifier: string]: string }   // 可能为空，详见 lazy enrichment
}
```

- `supportedBundleIds = ["com.apple.finder"]`
- `requiredPermissions = [.accessibility]`（attach 通过 hub 订阅 AX 通知；按上节"AX 消费 adapter 必须声明 `.accessibility`"，此处必须把它写进来。`.automation` 是 lazy enrichment 权限，不属于 attach 必需集）
- attach 仅做 hub 订阅与 stream 准备（参见 `SenseAdapter.attach` 契约：禁止 attach 内做同步 AX 属性读取或 AX 树遍历）。订阅 `kAXSelectedChildrenChangedNotification` 后立即返回 stream；`AXSelectedChildren` 的读取与 envelope emit 全部发生在 notification handler 内，**包括首次状态**——adapter 在 attach 返回后从自身 actor 上调度一次 handler 即可触发首屏读，与后续 AX 通知走同一条代码路径。`fileURLs` 在所有路径上初始为空，由 lazy enrichment 填充
- **Lazy enrichment**：用户点击 chip 时才通过 Apple Event `tell application "Finder" to get selection` 拉路径回填 `fileURLs`。首次调用触发 Automation 系统授权 prompt；未授予则 `fileURLs` 保持空，授权结果回报 `PermissionsService`，由 service 投影 `.automation` 到 `SenseContext.permissions`；chip 仍存在以便用户后续重试

### BrowserAdapter

emits `kind = "browser.tab"`，payload schema：

```ts
{
    url: string,
    pageTitle: string
}
```

- `supportedBundleIds = ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser"]`
- `requiredPermissions = [.accessibility]`（同 FinderAdapter 理由：通过 hub 消费 AX 通知必须声明）
- attach 仅做 hub 订阅与 stream 准备：订阅 app 元素级别的轻量通知（如 `kAXFocusedUIElementChangedNotification` / `kAXMainWindowChangedNotification`）后立即返回 stream，**不在 attach 内做 AX 树遍历**。地址栏 `AXTextField` 的定位与对其 `kAXValueChangedNotification` 的订阅延后到首次 notification handler 内进行，与 `SenseAdapter.attach` 契约一致
- 取不到地址栏时不输出 envelope

其他所有 app 一律不写 adapter，依赖 GeneralProbe。

## ScreenMirror（视觉兜底）

**定位**：当 `SenseContext.behaviors` 为空时，提供视觉 context 给 agent 理解"用户正在看什么"。

**核心范式：submit-time on-demand 捕获**。

视觉兜底**不是 live mirror**。Shell 进程不维护后台截图循环 —— Notch UI 关闭时无任何视觉相关 IO，打开后也只是显示一个"按 send 会附带窗口截图"的 chip。**只有用户真的点 send 时**才执行一次 `SCScreenshotManager.captureImage(...)` 单帧捕获。

这条范式是对早期 "1 fps SCStream live mirror" 设计的修正，原因：

- 隐私：Notch 打开 ≠ 用户授权连续截图。把捕获绑死在 submit 上让用户的同意是 explicit per-turn 的
- 性能：1 fps SCStream 是读侧最重的常驻负担（~50–100MB 内存 + frame 处理 CPU），而视觉只在提交时被消费一次，常驻流是浪费

**触发与 gate**：

- 能力可用性：`SenseStore.visualSnapshotAvailable` —— `app != nil && !permissions.denied.contains(.screenRecording)`。OS Sense 只回答"能不能截"。
- **何时截**：由 Shell 持有的 `VisualCapturePolicyStore` 决定，**与 OS Sense 解耦**。该 store 维护 per-bundleId 的"始终捕获"开关（process-only 内存，不持久化），UI 把开关绑在 app chip 右侧的 viewfinder 按钮上。submit 时 `ComposerCard` 检查当前 frontmost 的 bundleId 是否在 store 内：
  - 在 → `await senseStore.captureVisualSnapshot()`，得到的 `VisualMirror?` 作为 `visual:` 参数传给 `CitedContextProjection.project(from:selection:visual:clipboards:)`
  - 不在 → 传 `nil`，整个截图路径不执行
- 与 `behaviors` 的耦合解除：旧版"behaviors 非空就不截"的判定已废止。是否截图完全由 per-app 开关决定，由用户对该 app 的预设负责
- app 切换：开关状态按新 bundleId 重新查询，没设置的 app 默认关

**捕获单次性**：

- 实现：`SCShareableContent.current` 拿 frontmost window → `SCContentFilter(desktopIndependentWindow:)` → `SCScreenshotManager.captureImage(contentFilter:configuration:)` 单次返回 `CGImage`
- 下采样：长边 ≤ 1280px
- 体积约束：在 Shell 投影时按 base64 后大小 ≤ 400KB 校验，超限继续降采样（见 `CitedContextProjection`）

**不附 AX 树**。视觉兜底只服务于"看"。Computer Use 工具链独立捕获 AX 树。

## Clipboard capture

**定位**：剪贴板已退出 OS Sense 的 live mirror。OS Sense 不再轮询
`NSPasteboard.changeCount`，`SenseContext` 上也不再有 `clipboard` 字段。

**核心范式：composer-side, paste-event-driven**。

理由：始终镜像 pasteboard 不能区分"用户碰巧最近拷贝过什么"和"用户想把这
个内容引用进 prompt"。前者会把无关内容（密码管理器临时项、其他 app 的复制
回收）暴露给 LLM 直到用户主动取消勾选。粘贴这个 gesture 本身就是有意图的
信号——只在用户真的把 clipboard 粘到 AOS 输入框时，才把它作为可引用的
context 候选呈现。

**实现归属**：

- `ClipboardItem` 类型与 pasteboard 抽取规则（type priority、文本逐字捕获、
  image metadata-only）仍住在 `AOSOSSenseKit` 包里，作为 `ClipboardPasteboardExtractor.extract(from:)` 的纯函数 API。这条契约属于
  OS Sense 的投影规则
- 触发与状态归属于 Shell composer：`ChipInputView`（`AOSShell/Notch/Components/`，
  NSTextView wrapper）拦截 Cmd+V，调 extractor 一次性快照 `NSPasteboard.general`，
  把结果作为 `NSTextAttachment`（`ClipboardChipCell`）插入到 caret 位置；
  同一个 turn 可以插入多个 chip
- 内联 chip 渲染规则：每个 chip 显示 `[icon] <label>`（不展示内容预览，因为
  有意图的信号是"粘贴动作"而非内容），自带 X 按钮单独删除；Backspace 在
  chip 边界做原子删除
- 提交时：`ChipInputModel.snapshot()` 把 NSTextView 的 storage 投影成
  `(prompt, clipboards: [ClipboardItem])`——prompt 中 chip 位置写入
  `[[clipboard:N]]` marker，clipboards 数组按出现顺序排列；两者一起传给
  `CitedContextProjection.project(...)` 后清空整个输入框。Sidecar 在
  `buildUserMessage` 中把 marker 展开成 `<clipboard index="N+1" kind="…">…</clipboard>`，
  位置即语义
- app 切换：整个输入框（typed text + 所有 chips）一起清空——捕获时的 app
  与提交时的 app 不一致就视为失效

**保留的规则**（由 extractor 强制）：

- 类型优先级：`public.file-url` > `public.utf8-plain-text` > `public.image`
- 图片只返 metadata，绝不返像素
- 文本逐字捕获，业务语义"不截断"：手动粘贴是用户的显式意图，必须完整传给模型
  （GeneralProbe 的 selectedText / currentInput 同样不截断，理由相同）。
  `PayloadSizeGuard.clamp` 的 1 MiB 兜底是 defense-in-depth，仅在单条字符串异常巨大时触发并附标记，正常人类内容下永不命中

## 模块结构

```
packages/
  AOSOSSenseKit/
    Sources/AOSOSSenseKit/
      Core/                         # 不得 import Adapters/*
        SenseStore.swift            # @MainActor + @Observable，唯一写入入口
        AXObserverHub.swift         # 跨进程 AX 订阅与生命周期管理
        WindowMirror.swift          # NSWorkspace 前台 app/window 跟踪
        GeneralProbe.swift          # 通用 AX 行为采集（producer → envelope）
        ClipboardPasteboardExtractor.swift  # 纯函数：NSPasteboard → ClipboardItem
        ScreenMirror.swift
        AdapterRegistry.swift       # adapter 注册与路由（仅看 protocol + envelope）
        BehaviorEnvelope.swift      # envelope 类型 + JSONValue
        SenseAdapter.swift          # 协议定义
      Adapters/                     # 由 Shell composition root 注册
        FinderAdapter.swift         # 内部 FinderSelection 类型 → envelope 映射
        BrowserAdapter.swift        # 内部 BrowserTab 类型 → envelope 映射
    Tests/AOSOSSenseKitTests/
      GeneralProbeTests.swift
      AdapterRegistryTests.swift
      ScreenMirrorTests.swift
      FinderAdapterTests.swift
      BrowserAdapterTests.swift
```

`SenseStore` 是对外唯一入口。Shell 启动时构造一次。

## 与 AOS 主进程集成

```
┌─────────────────────────────────┐        ┌─────────────────────┐
│   AOS Shell (SwiftUI)           │        │  Bun Sidecar (TS)   │
│                                  │        │                     │
│   App launch                     │        │                     │
│       │                          │        │                     │
│       ▼                          │        │                     │
│   SenseStore.start()             │        │                     │
│       │ live mirror              │        │                     │
│       ▼                          │        │                     │
│   Notch UI ──@Bindable──         │        │                     │
│   - 折叠态：app icon / 状态指示   │        │                     │
│   - 展开态：app chip + 截图开关  │        │                     │
│              + behavior chips     │        │                     │
│              + paste-clipboard?   │        │                     │
│       │                          │        │                     │
│   user picks subset + submits    │        │                     │
│       │                          │        │                     │
│       ▼ project to wire schema  │        │                     │
│   agent.submit(prompt,           ├───────►│  citedContext:      │
│     citedContext: CitedContext)  │ JSON   │  CitedContext object│
│                                  │  RPC   │       │              │
│                                  │        │       ▼              │
│                                  │        │  组装 prompt → LLM  │
└─────────────────────────────────┘        └─────────────────────┘
```

- `AOSOSSenseKit` 作为 Swift package 直接链接进 Shell，进程级单例
- Shell 启动即 `SenseStore.start()`，常驻订阅 OS 事件
- Notch UI 通过 `@Bindable` 直接绑定 `SenseStore.context`
- 用户提交时，Shell 把勾选条目从 live `SenseContext` **投影**到 wire-only `CitedContext` object（schema 见 `designs/rpc-protocol.md`），再编码为 JSON 发给 Bun。`CitedContext` 是 object，不是裸 envelope 数组——`behaviors` 字段才是 `BehaviorEnvelope[]`，同时还会带 `app` / `window` / `visual` / `clipboard` 的引用快照
- `BehaviorEnvelope` 的四字段 `kind` / `citationKey` / `displaySummary` / `payload` 中，`payload` 完全 opaque，Bun 持有、序列化进 prompt、转发给 LLM
- LLM 凭 `kind` 与 `payload` 自行解读结构。Bun 不需要任何具体 Behavior 类型定义、不需要解码器
- 未勾选条目永不离开 Shell 进程；live model 不直接参与序列化

### 加新 adapter 的成本

1. 写 adapter 主体（attach / detach / 订阅 AX）
2. 在 adapter 内部定义其 payload 类型（Swift struct），实现到 `BehaviorEnvelope` 的映射
3. Shell composition root 注册 adapter

Core 包零改动；`SenseStore` / `BehaviorEnvelope` / RPC 层 / Bun agent 代码零改动。新增 adapter 不应触碰 `Core/` 下任一文件。

## Notch UI 渲染契约

Chip 行的最新组成：

```
contextChips = [appChip + viewfinderToggle] ++ behaviors
inputField   = typed text  +  inline clipboard chips (one per Cmd+V)
```

- **app chip + 截图开关**：常驻在最前面。viewfinder 按钮反映当前 frontmost 在 `VisualCapturePolicyStore` 中的开关状态；点亮 = 该 app 后续每次 send 都附窗口截图
- **behavior chips**：`SenseStore.context.behaviors` 投影；可单独取消勾选
- **inline clipboard chips**：每次 Cmd+V 在 caret 位置插入一个 `[icon] <label>` chip（attachment cell on `NSTextView`），自带 X 按钮单独删除；不展示内容预览，因为有意图的信号是"粘贴动作"。提交时位置即语义——sidecar 把每个 chip 展开成 `<clipboard index="N" kind="…">…</clipboard>` 在 prompt 原位

Core UI 只读 `Behavior.displaySummary` 渲染默认 chip。每个 adapter 可选注册一个 SwiftUI `BehaviorRenderer` 做富渲染（如显示 favicon、文件图标），与 adapter 同包发布。Core UI 对具体 Behavior 类型零依赖。

## 权限

权限探测一律走 Shell 级 `PermissionsService`，不在模块内自起探测路径。OS Sense 订阅 `PermissionsService` 发布的 `PermissionState`，状态翻转时即时调整自身行为：

- **Accessibility**：`GeneralProbe` 与 AX-based adapter 必需。`PermissionsService` 用 `AXIsProcessTrusted()` 探测；缺失则 `SenseStore` 进入 degraded 模式（仅 `WindowMirror`，且 `WindowIdentity.windowId` 为 nil），授权后无需重启即可补订阅
- **Screen Recording**：`ScreenMirror.captureNow(forPid:)` 必需。`PermissionsService` 以 `SCShareableContent.current` 为真值（异步、低频调用、缓存结果），可选用 `CGPreflightScreenCaptureAccess()` 作为 fast-path cache hint；缺失则 `visualSnapshotAvailable` 恒为 false，submit 时也不会去捕获
- **Automation**：仅 `FinderAdapter` 使用。用户点击 Finder selection chip 时按需触发系统 prompt，授权结果回写到 `PermissionsService`

不申请 Input Monitoring。

## 已知风险

| 风险 | 缓解 |
|---|---|
| Electron / Figma 等 app AX 通知不稳 | GeneralProbe 通道失败即缺省；视觉兜底自动接管 |
| `AXObserver` 跨进程消息阻塞主线程 | `AXObserverHub` 把每个 pid 的 observer source 挂到 main runloop，所有 AX 调用与回调都收敛到 `@MainActor` 单一隔离边界；app deactivate 时立即 detach |
| `AXValueChangedNotification` 在 IDE / 终端逐字符触发 | 250ms debounce |
| Finder Apple Event 首次需用户授权 | 仅在用户**点击 chip** 时触发 Apple Event |
| `SCScreenshotManager` 单次捕获延迟约 100–200ms | submit 路径已经是 async；用户感知为 send 后短暂等待，不阻塞 UI |
| 全屏游戏 / DRM 内容下截图黑屏 | `visual` 设为 nil |
| 剪贴板含敏感内容（密码） | 已通过"只在用户主动粘贴时捕获"消解：未粘贴 → 永不暴露；粘贴 → 用户可点 chip 丢弃 |
| Adapter 长时间未释放订阅 | `AdapterRegistry` 在 detach 时强制收回 hub 资源；timeout 也触发强制 detach |

## 不做的事

- 不做 event tap / 鼠标键盘事件流
- 不做 Input Monitoring 权限申请
- 不做 selection / clipboard / behavior 历史
- 不做跨 app attention transition 分析
- 不做 context 相关性排序；所有条目平铺，由用户决定引用
- live mirror 内不做主动 snapshot：`SenseContext` 字段只由 OS 事件源（`NSWorkspace` / AX notification）驱动。submit-time 的视觉单帧捕获（`SenseStore.captureVisualSnapshot()`）与 paste-time 的剪贴板捕获是 **Shell composer 的提交路径**职责，不进 live mirror，OS Sense 不轮询 pasteboard、不做后台连续截图
- 不在 OS Sense 内决定截图策略；何时截图属于 Shell 的 `VisualCapturePolicyStore`
- 不为 app 写非插件化的 specific 分支
- 不允许 Adapter 影响 GeneralProbe 判定逻辑
- 不在视觉兜底里附 AX 树
- 不暴露为 MCP tool
- 不向 Bun 推未被引用的条目
- 不在 public schema 暴露 app-specific 字段
- 不在 Bun 端定义 Behavior 类型
- 不做 browser AppleScript fallback
