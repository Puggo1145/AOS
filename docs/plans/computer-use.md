# Computer Use 实现计划

设计依据：[docs/designs/computer-use.md](../designs/computer-use.md)

## 实现阶段

### Stage 1：底层 SPI + Focus Guard

- `SkyLightEventPost`：`SLEventPostToPid` + `SLSEventAuthenticationMessage` + `CGEventSetWindowLocation` + raw-field SPI + `_SLPSGetFrontProcess` / `GetProcessForPID` / `SLPSPostEventRecordTo` + `SLSGetActiveSpace` / `SLSCopySpacesForWindows` 全部解析
- `FocusWithoutRaise.activateWithoutRaise` 完整 yabai 配方
- `FocusGuard` 三层完整实现
- `_AXUIElementGetWindow` 链接，`WindowEnumerator` + `SpaceDetector`
- Swift Testing 覆盖：所有 SPI 解析、248 字节事件记录构造、focus state 还原、negative cache、frontmost 检测
- grep 校验：所有非-frontmost 路径无 `CGEventPost(tap: .cghidEventTap)`

### Stage 2：AX 快照 + 操作链路

- `AccessibilitySnapshot` 含 Chromium 激活（AXObserver + main runloop + 500ms pump）
- `StateCache` 按 `(pid, windowId)` 键 + TTL 30s
- `AXInput` 含 hit-test 5×5 grid 自校准
- `MouseInput` 后台走 focus-without-raise + primer 配方，frontmost 走 HID tap
- `KeyboardInput` 走 SkyLight auth-signed → CGEvent.postToPid 降级
- `WindowCapture` 三档 capture mode
- `Permissions` + `doctor` 结构化状态

### Stage 3：Shell RPC handlers

- `ComputerUseHandlers.swift` 实现 9 个 `computerUse.*` method 的 async handler
- `AOSRPCSchema` 定义各 method 的 params / result Codable 类型，`sidecar/src/rpc-types.ts` 手写对应 TS 类型，fixture conformance test 保证一致
- per-method timeout（见 rpc-protocol.md）
- Bun 侧 tool registry 按 LLM provider 格式包装 tool，execute 走 RPC client
- e2e：从 Bun 发起 `rpc.call("computerUse.click", ...)` 到 Kit 真实点击的完整链路

### Stage 4：覆盖率验证

- Native AX：TextEdit、Finder、Safari、Calculator
- Chromium-family：Chrome、Slack、VS Code、Cursor、Notion、Figma、Linear desktop
- 每个 app 的 SkyLight 路径、AXObserver 激活、focus suppression、Space 检测都需独立验证
- 记录每个 app 成功率

### Stage 5：Shell 集成

- 权限引导流（Accessibility / Screen Recording）完整串联 Kit 的 `Permissions` 校验
- Bun 在 agent 调用前通过 `computerUse.doctor` 做前置自检，权限或 SPI 缺失直接给用户反馈而不是 tool 失败
- Notch UI 增加"正在后台操作 X app"状态指示（由 Bun 的 `ui.status` 驱动）

## 验证标准

Stage 1：

- `doctor.skyLightSPI` 全部 true
- 对 Chrome 后台 omnibox 输入并 commit URL，过程中 `NSWorkspace.frontmostApplication` 不变、Chrome 窗口 z-rank 不变、不触发 Space follow
- 对 Slack 后台输入消息（不发送），目标窗口未自激活到前台

Stage 2：

- TextEdit "新文档 → 输入文本 → 保存" 全后台完成，过程中 frontmost app 不变
- VS Code 首次 snapshot 元素数 ≥ 200（Chromium AX 树成功激活）
- 同一 Chrome pid 两个不同 window 的 elementIndex 不互相污染
- 目标 window 在另一 Space 时 `getAppState` 返回 `ErrWindowOffSpace`

Stage 3：

- Bun 侧 `rpc.call("computerUse.click", ...)` 端到端能触发 Kit 点击并返回结构化结果
- Swift + TS 双侧 fixture roundtrip 全部 byte-equal
- 错误码路径全覆盖：`ErrStateStale`（-32100）、`ErrOperationFailed`（-32101）、`ErrWindowMismatch`（-32102）、`ErrWindowOffSpace`（-32103）、`ErrPayloadTooLarge`（-32001）、`ErrTimeout`（-32002）

Stage 4：

- 11 个目标 app 综合成功率 ≥ 80%
- Chromium-family 7 个 app 单独成功率 ≥ 75%
- 失败路径均由 agent 收到明确错误码，无静默失败
