# OS Sense 实现方案

## 目标

在用户打开 Notch UI 的**那一刻**，snapshot 一次用户当前的可引用状态，作为 agent context。让 agent 感知用户正在看什么、选了什么、在哪打字、复制了什么。

非目标（本阶段不做）：
- 后台持续监控用户行为
- 鼠标轨迹 / 键盘输入流 / 滚动事件采集
- 剪贴板历史、selection 历史、操作回放
- 屏幕 / 窗口状态的 diff 追踪
- 跨 app 的 attention transition 分析

## 核心范式：snapshot-on-open

用户召唤 Notch UI 的时机即 intent 信号。那一刻的 OS 状态就是 context。

触发入口只有一个：AOS Shell 检测到 Notch UI 打开 → 同步调用 snapshot → 得到 context → 交给 Bun sidecar。

本 kit 不监听任何输入事件、不常驻后台、不维护历史。

## Context 数据结构

```swift
struct SenseContext {
    let app: AppIdentity          // 必有
    let window: WindowIdentity?   // frontmost window 标识
    let behaviors: [Behavior]     // 当前 app 内识别到的高价值行为
    let appSnapshot: PNGImage?    // 兜底截图：仅当 behaviors 为空时
    let clipboard: ClipboardItem? // 独立项，跨 app
}

struct AppIdentity { bundleId, name, pid }
struct WindowIdentity {
    title: String
    url: String?                                // 浏览器场景：当前 tab URL；非浏览器为 nil
}

enum Behavior {
    case selectedText(content: String)
    case selectedItems(items: [SelectedItem])
    case currentInput(value: String)            // focused 输入框的未提交内容
}

struct SelectedItem {
    role: String
    label: String
    identifier: String?
    path: String?                               // Finder 场景：POSIX 文件路径；其他为 nil
}

enum ClipboardItem {
    case text(String)
    case filePaths([URL])
    case image(metadata: ImageMetadata)         // 只给 {width, height, type}，不给像素
}
```

## Behavior 识别规则

三类 behavior，遵循"显式 intent"原则。采集仅通过通用 API，不做 per-app 特例判断（除下文列出的两个）。

| Behavior | 采集来源 | 识别条件 |
|---|---|---|
| `selectedText` | `AXSelectedText` 属性 | 该属性存在且非空 |
| `selectedItems` | `AXSelectedChildren` / `AXSelectedRows` 属性 | 返回数组非空 |
| `currentInput` | `AXFocusedUIElement` 的 `AXValue` | focused 元素是可编辑文本域且 value 非空，且未被 `selectedText` 覆盖 |

**去重**：`selectedText` 与 `currentInput` 可能来自同一元素；当两者都成立时，只保留 `selectedText`。

**长度上限**：文本类 behavior 超过 2KB 截断，末尾附 `[truncated, N more chars]`。

**selectedItems 不递归**：只返直接选中的那一层，不展开子元素。每项结构见上方 `SelectedItem`。

## Per-app adapter（仅两个例外）

1. **Finder — 选中文件的 POSIX path**  
   通过 Apple Event `tell application "Finder" to get selection` 拿路径。识别到 `bundleId == "com.apple.finder"` 时触发，结果填入 `SelectedItem.path`。需要 Automation 权限（见权限节）。

2. **浏览器 — 当前 tab 的 URL**  
   Chrome / Safari / Arc 的 URL 通过 AX 地址栏读取，填入 `WindowIdentity.url`。AX 取不到时 `url` 为 `nil`，不走 AppleScript fallback。

**其他所有 app**（VS Code / Notion / Slack / iTerm / Mail / ...）一律走通用 AX 通道，不写 adapter。

## 兜底截图规则

**触发条件（严格）**：当前 frontmost app 的 `behaviors` 数组为空。

**不触发的情况**：
- `behaviors` 非空（哪怕只有一项）
- 只有 `clipboard` 有内容但 `behaviors` 为空 → **仍然触发**（剪贴板是跨 app 独立项，不影响判定）

**截图参数**：
- 范围：当前 app 的 frontmost window（不是全屏，不是其他 app）
- API：`SCStream` + `SCContentFilter(desktopIndependentWindow:)`
- 下采样：长边 ≤ 1280px，PNG 压缩
- 大小上限：400KB，超限则进一步降采样至满足

**不附 AX 树**。兜底截图只作为视觉 context 提供给 agent 理解用户在看什么。若用户后续 prompt 要求操作，由 Computer Use 工具链独立捕获 AX 树。

## 剪贴板处理

- 读取 `NSPasteboard.general`，按最高优先级类型解析
- 优先级：`public.file-url` > `public.utf8-plain-text` > `public.image`
- 图片只返 metadata（`width / height / type`），**绝不返 base64 / 像素数据**
- 文本超过 2KB 截断规则同 behavior
- 与当前 app 无关，始终独立字段返回

## 模块结构

```
packages/
  AOSOSSenseKit/
    Sources/AOSOSSenseKit/
      SenseService.swift            # 对外门面，编排一次 snapshot
      BehaviorProbe.swift           # 通用 AX behavior 采集
      FinderAdapter.swift           # Finder Apple Event：选中文件路径
      BrowserAdapter.swift          # Safari / Chrome / Arc：AX 地址栏 URL
      WindowScreenshotter.swift     # SCStream 窗口截图 + 下采样
      ClipboardReader.swift         # NSPasteboard 读取
    Tests/AOSOSSenseKitTests/
```

`SenseService.snapshot()` 是唯一的对外方法，async 返回 `SenseContext`。

## 与 AOS 主进程的集成

```
┌─────────────────────────────────┐        ┌─────────────────────┐
│   AOS Shell (SwiftUI)           │        │  Bun Sidecar (TS)   │
│   Notch UI opens                │        │                     │
│       │                         │        │                     │
│       ▼                         │        │                     │
│   SenseService.snapshot()       │        │                     │
│       │                         │        │                     │
│       ▼                         │        │                     │
│   local memory                  │        │                     │
│   (chips rendered in Notch UI)  │        │                     │
│       │                         │        │                     │
│   user picks subset + submits   │        │                     │
│       │                         │        │                     │
│       ▼                         │        │                     │
│   agent.submit(prompt,          ├───────►│  citedContext →     │
│     citedContext)               │ JSON   │  agent              │
└─────────────────────────────────┘ RPC    └─────────────────────┘
```

- `AOSOSSenseKit` 作为 Swift package 直接链接进 AOS Shell
- Notch UI 打开 → Shell 调 `SenseService.snapshot()` → 完整 `SenseContext` 留在 Shell 本地内存
- Notch UI 渲染每个 behavior / clipboard / 截图为可点击 chip
- 用户点选后 submit → Shell 只把勾选的子集通过 `agent.submit.citedContext` 发给 Bun
- Bun 永不持有未被用户引用的条目
- 不暴露 MCP server，不做 agent-pull 接口

## 权限

- **Accessibility**：behavior 采集、AX 地址栏读取。与 Computer Use 共用，启动时 `AXIsProcessTrusted()` 校验
- **Screen Recording**：兜底截图。与 Computer Use 共用，启动时 `CGPreflightScreenCaptureAccess()` 校验
- **Automation**：仅 Finder adapter 使用。按需 per-app 触发——用户首次引用 Finder 文件时系统弹出 prompt。未授予则 `FinderAdapter` 返回 `permissionDenied(.automation)`

**不申请** Input Monitoring。

权限缺失时 `SenseService.snapshot()` 对应字段置空，并在返回值中带 `permissionDenied: [.accessibility | .screenRecording | .automation]` 标记。

## 与 Computer Use 的代码复用

两个 kit 各自独立实现 AX 读取与 SCStream 截图，不共享底层 package。

## 实现阶段

### Stage 1：核心 snapshot 能力
- `SenseService` + `BehaviorProbe` + `ClipboardReader` 实现
- Swift Testing 单测：behavior 识别规则、截断逻辑、去重规则、剪贴板类型优先级
- 基于 TextEdit 的 smoke test：选中文本 / 未选中 两种情况产出正确 `SenseContext`

### Stage 2：app adapter
- `FinderAdapter`（Apple Event 拿文件路径）
- `BrowserAdapter`（Safari / Chrome / Arc 的 URL 提取）
- e2e 测试：各自在真实 app 上验证

### Stage 3：兜底截图
- `WindowScreenshotter` 实现（SCStream + 下采样）
- 触发规则集成进 `SenseService`
- 测试：空 behavior 场景返回合规截图；非空 behavior 场景不截图

### Stage 4：Shell 集成
- AOS Shell 的 Notch 打开事件连上 `SenseService.snapshot()`，完整 `SenseContext` 保存在 Shell 本地内存
- Notch UI 渲染每个 behavior / clipboard / 截图为可点击 chip
- 用户提交时，Shell 把勾选条目组装为 `citedContext`，通过 `agent.submit` 发给 Bun
- 未勾选的条目在 Notch 关闭时释放，不跨 turn 保留

## 验证标准

Stage 1 完成判定：
- 在 TextEdit 里"选一段文字 → 打开 Notch" → `behaviors` 包含 `selectedText` 且内容匹配
- "未选中 → 打开 Notch" → `behaviors` 为空，**此阶段不触发截图**（Stage 3 才接入）
- `currentInput` 和 `selectedText` 同时成立时只保留 `selectedText`

Stage 3 完成判定：
- 在 Figma 窗口前打开 Notch（无 selection / 无 input） → 返回的 `appSnapshot` 尺寸 ≤ 1280px 长边、体积 ≤ 400KB
- 同样场景下 `NSWorkspace.frontmostApplication` 不变
- 有任一 behavior 时 `appSnapshot` 为 `nil`

Stage 4 完成判定：
- 端到端：选中文本 → 打开 Notch → UI 出现 `selected_text` chip → 用户点击 → 引用进入 prompt → 发送给 agent → agent 收到的 `citedContext` 包含该文本
- 未被勾选的 chip 对应的条目，在 Bun 进程的 RPC 日志和 agent session 内存里均不出现
- 单次 snapshot 总耗时 < 200ms（含截图场景）

## 已知风险

| 风险 | 缓解 |
|---|---|
| 某些 app 的 AX 对 `AXSelectedText` 暴露不稳（如 Electron） | 通用通道失败即失败，对应 behavior 缺省 |
| 浏览器 AX 地址栏在某些布局下取不到 URL | `WindowIdentity.url` 置 nil |
| Finder Automation 权限首次使用需用户确认 | `FinderAdapter` 在首次调用时触发系统 prompt；未授予返回 `permissionDenied(.automation)` |
| 兜底截图在全屏游戏 / DRM 内容下黑屏 | `appSnapshot` 返 nil，agent 侧可感知 |
| 剪贴板里是敏感内容（密码管理器刚复制的密码） | 不做内容判断，由用户决定是否点击引用 |
| Notch 打开事件频繁触发导致 snapshot 过多 | UI 层 debounce 200ms；本 kit 不做缓存 |

## 不做的事

- 不做 event tap / 鼠标键盘事件监听
- 不做后台常驻监控
- 不做 clipboard 历史、selection 历史
- 不做跨 app 的 attention transition 分析
- 不做 Input Monitoring 权限申请
- 不做 context 相关性排序；所有 context 平铺暴露，由用户点击决定引用
- 不做除 Finder / 浏览器外的 per-app adapter
- 不做 browser AppleScript fallback
- 不把未勾选的 sense 条目下推给 Bun
- 不在 OS Sense 返回的截图里附 AX 树
- 不暴露为 MCP tool
