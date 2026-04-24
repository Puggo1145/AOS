# OS Sense 实现计划

设计依据：[docs/designs/os-sense.md](../designs/os-sense.md)

## 实现阶段

### Stage 0：基础设施
- `AXObserverHub`、`WindowMirror`、`SenseStore`、`BehaviorEnvelope` + `JSONValue`、`SenseAdapter` 协议骨架
- `SenseStore.context` 可被外部观察

### Stage 1：通用通道
- `GeneralProbe` + 三个 built-in kind 输出 + `ClipboardWatcher`
- 单测：识别规则、去重、截断、剪贴板优先级

### Stage 2：Adapter 协议与内置实现
- `AdapterRegistry`、失败隔离、权限缺失路径
- `FinderAdapter`（`finder.selection`）
- `BrowserAdapter`（`browser.tab`）
- e2e：Finder 选文件、Chrome 切 tab → 对应 envelope 实时出现

### Stage 3：视觉兜底
- `ScreenMirror` 启停规则集成进 `SenseStore`

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
- `general.selectedText` 与 `general.currentInput` 同时成立时只保留前者

**Stage 2**：
- Finder 选文件 → `general.selectedItems` 与 `finder.selection` 两个 envelope 同时出现（`finder.selection.payload.fileURLs` 初始为空）；点击 `finder.selection` chip 时（首次）触发 Automation 权限 prompt；授权后 `fileURLs` 填充
- Chrome 切 tab → `browser.tab` envelope 的 `payload.url` 在 250ms 内更新
- `BrowserAdapter` 抛错或 timeout → `browser.tab` envelope 缺失；`GeneralProbe` 与 `FinderAdapter` 不受影响
- 静态检查：`Core/*` 任一文件不出现 `FinderAdapter` / `BrowserAdapter` / `finder.selection` / `browser.tab` 字面量

**Stage 3**：
- Figma 前台、无 selection / input → `visual.latestFrame` 在 1s 内有效，长边 ≤ 1280px
- 在 Figma 选中元素 → `visual` 立即变为 nil，SCStream 停止

**Stage 4**：
- 端到端：选中文本 → Notch 折叠态指示器更新 → 展开 → 点击 chip → 提交 → Bun RPC 收到包含该 envelope JSON 的 `citedContext`
- 未勾选 chip 对应条目，在 Bun RPC 日志和 LLM prompt 内均不出现
- Notch 关闭后再打开 → 显示当前最新状态，不是上次关闭时的状态
