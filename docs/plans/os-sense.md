# OS Sense 实现计划

设计依据：[docs/designs/os-sense.md](../designs/os-sense.md)

## 实现阶段

### Stage 0：基础设施
- `AXObserverHub`、`WindowMirror`、`SenseStore`、`BehaviorEnvelope` + `JSONValue`、`SenseAdapter` 协议骨架
- `SenseStore.context` 可被外部观察

### Stage 1：通用通道
- `GeneralProbe` + 三个 built-in kind 输出 + `ClipboardWatcher`
- 单测：识别规则、selection/input 并列输出、截断、剪贴板优先级

### Stage 2：Adapter 协议与内置实现
- `AdapterRegistry`、失败隔离、权限缺失路径
- `FinderAdapter`（`finder.selection`）
- `BrowserAdapter`（`browser.tab`）
- `PreviewAdapter`（`pdf.document`）
- e2e：Finder 选文件、Chrome 切 tab、Preview 打开 PDF → 对应 envelope 实时出现

### Stage 3：视觉兜底（submit-time）
- `ScreenMirror.captureNow(forPid:)` 单次捕获 API
- `SenseStore.visualSnapshotAvailable` gate（app + screen-recording grant），暴露 `captureVisualSnapshot()` 给 Shell
- Shell 在 `AgentInputField.submit()` 内按 chip 选中状态调用一次 `captureVisualSnapshot()`，结果作为参数传入 `CitedContextProjection.project(from:selection:visual:)`

### Stage 4：Shell 集成
- Shell 启动时构造 `SenseStore`
- Notch UI 折叠态绑定 `app.icon` / `app.name`；展开态遍历 `behaviors` 渲染 chip
- 用户提交时 Shell 把勾选 envelope 编码为 JSON 数组发给 Bun

## 验证标准

**Stage 0**：
- 切换前台 app（不打开 notch）→ Notch 折叠态 icon 在 100ms 内同步切换

**Stage 1**：
- TextEdit 选一段文字 → 不打开 notch → 打开 notch 时 chip 已在场，与当前 selection 一致
- 选中后再取消 → chip 同步消失，无残留
- `general.textSelection` / `general.selectedText` 与 `general.currentInput` 同时成立时并列输出；selection chip 表示选中内容，input chip 表示当前可编辑目标；exact textSelection 已携带内容时 currentInput 可只带 target

**Stage 2**：
- Finder 选文件 → `general.selectedItems` 与 `finder.selection` 两个 envelope 同时出现（`finder.selection.payload.fileURLs` 初始为空）；点击 `finder.selection` chip 时（首次）触发 Automation 权限 prompt；授权后 `fileURLs` 填充
- Chrome 切 tab → `browser.tab` envelope 的 `payload.url` 在 250ms 内更新
- Preview 打开 PDF → `pdf.document` envelope 的 `payload.fileURL` 在 250ms 内更新；Preview 打开非 PDF 图片不输出 `pdf.document`
- `BrowserAdapter` 抛错或 timeout → `browser.tab` envelope 缺失；`GeneralProbe` 与 `FinderAdapter` 不受影响
- 静态检查：`Core/*` 任一文件不出现 `FinderAdapter` / `PreviewAdapter` / `BrowserAdapter` / `finder.selection` / `pdf.document` / `browser.tab` 字面量

**Stage 3**：
- Figma 前台、无 selection / input、screen-recording 已授权 → Notch 展开后 chip 出现 "Window snapshot"，但**不发生任何截图捕获**（Activity Monitor 验证 Notch Agent Shell 进程无 SCStream）
- 用户在 Figma 选中元素 → 视觉 chip 自动从 row 中消失（`behaviors.isEmpty` 不再成立），仍未捕获任何截图
- 用户保持视觉 chip 选中 → 点 send → Shell 单次调用 `SCScreenshotManager.captureImage(...)`，长边 ≤ 1280px 的 PNG 出现在 RPC `citedContext.visual.frame`
- 用户取消视觉 chip 选中 → 点 send → RPC 中 `visual` 字段缺失，未发生捕获

**Stage 4**：
- 端到端：选中文本 → Notch 折叠态指示器更新 → 展开 → 点击 chip → 提交 → Bun RPC 收到包含该 envelope JSON 的 `citedContext`
- 未勾选 chip 对应条目，在 Bun RPC 日志和 LLM prompt 内均不出现
- Notch 关闭后再打开 → 显示当前最新状态，不是上次关闭时的状态
