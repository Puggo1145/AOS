# Computer Use Foundation 设计

## 当前边界

Computer Use 现在只保留 macOS app/window/snapshot/capture foundation。它不再暴露给 Sidecar，也不再包含任何 app 操作能力。

已移除：

- Shell `computerUse.*` JSON-RPC handler
- Sidecar `computer_use_*` tools
- Focus / Input / VisualCursor
- SkyLight event posting、keyboard/mouse injection、focus suppression
- Dev Mode 操作 workbench 与 coordinate reliability target

## 保留模块

```
Sources/AOSComputerUseKit/
  AOSComputerUseKit.swift
  ComputerUseService.swift
  Apps/
    AppInfo.swift
    AppEnumerator.swift
  Windows/
    WindowInfo.swift
    WindowEnumerator.swift
    WindowCoordinateSpace.swift
  AppState/
    AccessibilitySnapshot.swift
    TreeRenderer.swift
    StateCache.swift
  Capture/
    WindowCapture.swift
    ScreenInfo.swift
```

`AOSComputerUseKit` 仍依赖 `AOSAXSupport`，用于 shared AX primitives、Chromium / Electron web accessibility activation、`_AXUIElementGetWindow` bridging、locator support。`AOSOSSenseKit` 和 `AOSComputerUseKit` 可以共同依赖 `AOSAXSupport`，但不得互相依赖。

## Public API

`ComputerUseService` 是当前唯一门面：

- `listApps(mode:) -> [AppInfo]`
- `listWindows(pid:) -> [WindowInfo]`
- `getAppState(pid:windowId:captureMode:maxImageDimension:) -> AppStateBundle`

`getAppState` 支持三种 capture mode：

- `som`：AX tree + screenshot
- `vision`：仅 screenshot
- `ax`：仅 AX tree

该 API 是 in-process Swift API。当前没有 JSON-RPC schema、Sidecar tool schema 或 Shell handler 绑定它。Dev Mode 可以直接注入 `ComputerUseService` 做本地 diagnostics，但该入口只允许查看 foundation 输出，不允许执行 app 操作。

## 数据流

```mermaid
flowchart TD
  Caller["Swift caller"] --> Service["ComputerUseService actor"]
  DevMode["Dev Mode Computer Use diagnostics"] --> Service
  Service --> Apps["AppEnumerator"]
  Service --> Windows["WindowEnumerator"]
  Service --> Snapshot["AccessibilitySnapshot"]
  Service --> Cache["StateCache"]
  Service --> Capture["WindowCapture"]
  Snapshot --> AXSupport["AOSAXSupport"]
```

## 约束

- 不做 app 操作。
- 不注入鼠标或键盘事件。
- 不 suppress 或修改系统焦点。
- 不注册 Sidecar tool。
- 不通过 JSON-RPC 暴露 Computer Use。
- 不保留操作相关 fallback 或 stub。

未来重写 app 操作能力时，应在这个 foundation 上新增明确边界，而不是重新引入隐式 handler 或半可用 tool surface。
