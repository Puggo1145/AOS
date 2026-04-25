# Onboarding 实现计划

设计依据：
- [docs/designs/notch-ui.md](../designs/notch-ui.md)
- [docs/designs/llm-provider.md](../designs/llm-provider.md)（本轮需要修订"sidecar 运行时永不发起 login"约束）
- [docs/designs/rpc-protocol.md](../designs/rpc-protocol.md)（本轮需要修订 namespace 表 + 错误码段）

## 目标

Notch 在 sidecar 没有可用 LLM provider 时，opened 态展示 Onboarding 面板：列出可接入的 provider，用户点击触发完整 OAuth/PKCE 流程，登录成功后自动切回正常 input 面板。

两类进入 onboarding 的路径：

1. **启动期**：`~/.aos/auth/chatgpt.json` 缺失或 schema 损坏 → `provider.status` 直接返回 `unauthenticated`
2. **运行期**：token 文件存在但 refresh 失败（refresh token 已失效 / endpoint 拒绝）→ runtime 侧 `readChatGPTToken()` 把失效文件 rename 到 `chatgpt.json.invalid` 并抛 `AuthInvalidatedError`，agent loop 同时发 `ui.error` 与 `provider.statusChanged { state: "unauthenticated", reason: "authInvalidated" }`，Shell 收到后切回 onboard

`provider.status` 不做网络 refresh，只做磁盘存在 + schema 检查；refresh 验证由真正的 LLM 调用承担。这避免启动阻塞，也保证运行期失效能立即反映到 UI 而不是死循环。

本轮唯一可选 provider：`chatgpt-plan`（Codex / ChatGPT Subscription）。

## 非目标

- 多 provider 选择策略
- 设置页：主动登出、切账号、查看 token 状态
- API key 手输路径（OAuth-only）
- 多账号
- Onboarding 期间允许 `agent.submit`

## 关键架构决策

### OAuth loopback server 跑在 sidecar

修订 `docs/designs/llm-provider.md` 里"sidecar 运行时永不发起 login"那条。原因（"避免与 stdio RPC 冲突"）不成立——loopback HTTP 是独立 socket，与 stdio NDJSON 物理隔离；浏览器是 Shell 通过 `NSWorkspace.open` 打开的，sidecar 进程内只 listen `127.0.0.1:0` 接 callback。

复用 `sidecar/src/llm/auth/oauth/chatgpt-plan.ts` 现有的 `buildAuthorizeUrl` / `exchangeCode` / `writeChatGPTPlanToken`；把 CLI 里的 `startCallbackServer` 抽到共享文件，并补上 abort / 幂等 close / signal 透传契约。

CLI login 入口（`bun run …/chatgpt-plan.ts login`）保留：开发期 / 排障路径不依赖 Shell。

### 一次只允许一个 in-flight login

Sidecar 内用 `loginInflight: LoginSession | null` 单例。第二次 `provider.startLogin` 在已有未完成 session 时返回 `ErrLoginInProgress`。

### Wire schema 拆两个 notification

`provider.loginStatus` 与 session 绑定（要求 `loginId`），`provider.statusChanged` 是 provider 级广播（不绑 session）。理由：discriminated union 在 Swift Codable 同步成本高且易误用；两个 method 让 fixture / 类型 / 调用点都更直白。

### Storage 写盘边界

`storage.ts` 是唯一 fs 接触点。两个**受控写入路径**：

| 入口 | 触发 |
|---|---|
| `auth/runtime.ts` → `writeChatGPTPlanToken` | `provider.startLogin` 完成、首次落盘 |
| `llm/auth/oauth/chatgpt-plan.ts` 内 `readChatGPTToken` → `writeChatGPTPlanToken` | runtime LLM 调用触发 refresh，refresh 成功原子更新 |

refresh **失败**路径：`renameSync(path, path + ".invalid")` 后抛 `AuthInvalidatedError`。`provider.status` 与 `env-api-keys` 仍只看 `chatgpt.json`，`.invalid` 文件天然忽略。login 成功重新写入 `chatgpt.json` 时若存在 `.invalid` 则删除（避免遗留）。

### Provider 方向约束

`provider.*` 在 dispatcher 里设为 `both`（与 `rpc` 同档）。承认这弱化了 namespace-level 方向约束——method-level direction 不值得为单 namespace 改 dispatcher 架构。补救：

- `docs/designs/rpc-protocol.md` 新增 namespace 子表，列出 `provider.*` 每个 method 的精确方向
- 单测覆盖：`dispatcher.notify("provider.status", {})` 抛错（request method 不该当 notification 发）；`dispatcher.notify("provider.loginStatus", {...})` 正常工作；handler 注册只发生在 method 名匹配的方向上

## 新增 RPC 契约

错误码新段：`-32200 ~ -32299` `auth.*`

| 码 | 常量名 | 含义 |
|---|---|---|
| `-32200` | `loginInProgress` | 已有未完成的 login session |
| `-32201` | `loginCancelled` | session 被显式 cancel |
| `-32202` | `loginTimeout` | 超过 5min 没有 callback |
| `-32203` | `unknownProvider` | `providerId` 不在已知列表 |
| `-32204` | `loginNotConfigured` | client_id / endpoint 未配置（VERIFY 期间） |

### `provider.*` namespace（双向 = `both`）

| Method | 方向 | 类型 | Params | Result |
|---|---|---|---|---|
| `provider.status` | Shell → Bun | request | `{}` | `{ providers: ProviderInfo[] }` |
| `provider.startLogin` | Shell → Bun | request | `{ providerId }` | `{ loginId, authorizeUrl }` |
| `provider.cancelLogin` | Shell → Bun | request | `{ loginId }` | `{ cancelled }` |
| `provider.loginStatus` | Bun → Shell | notification | `{ loginId, providerId, state, message?, errorCode? }` | — |
| `provider.statusChanged` | Bun → Shell | notification | `{ providerId, state, reason?, message? }` | — |

```ts
interface ProviderInfo {
  id: string;            // "chatgpt-plan"
  name: string;          // "Codex (ChatGPT) Subscription"
  state: "ready" | "unauthenticated";
}
type ProviderLoginState = "awaitingCallback" | "exchanging" | "success" | "failed";
type ProviderState = "ready" | "unauthenticated";
type ProviderStatusReason = "authInvalidated" | "loggedOut";

interface ProviderStartLoginResult {
  loginId: string;
  authorizeUrl: string;
}
interface ProviderCancelLoginResult {
  cancelled: boolean;     // false 表示 session 已结束（success / failed）
}

interface ProviderLoginStatusParams {
  loginId: string;
  providerId: string;
  state: ProviderLoginState;
  message?: string;
  errorCode?: number;     // failed 时的 -32200 段码
}
interface ProviderStatusChangedParams {
  providerId: string;
  state: ProviderState;
  reason?: ProviderStatusReason;
  message?: string;
}
```

### startLogin 失败契约

预检查 / 配置类失败走 **JSON-RPC error response**，不创建 session、不发 notification：

| 场景 | error code |
|---|---|
| `providerId` 不识别 | `-32203 unknownProvider` |
| 已有未完成 session | `-32200 loginInProgress` |
| `CHATGPT_PLAN_CLIENT_ID == "TBD"` | `-32204 loginNotConfigured` |

通过预检查后，sidecar 创建 `loginId` + 起 loopback + 立即返回 `{ loginId, authorizeUrl }`；后台 task 进度走 `provider.loginStatus` notification。

Shell 侧调 `startLogin`：捕到 `RPCMethodError` → inline 错误条；正常 result → 调 `NSWorkspace.open` 打开浏览器，进入"等回调"UI。

### typed auth error 传播（不依赖正则）

```ts
// sidecar/src/llm/auth/oauth/chatgpt-plan.ts
export class AuthInvalidatedError extends Error {
  constructor(public readonly providerId: string, public readonly reason: string) {
    super(`provider ${providerId} auth invalidated: ${reason}`);
    this.name = "AuthInvalidatedError";
  }
}
```

`AssistantMessage`（`llm/types.ts`）扩两个可选字段（不破坏 guide §3 的开放结构）：

```ts
errorReason?: "authInvalidated" | "contextOverflow" | "permissionDenied";
errorProviderId?: string;
```

provider stream 顶层 `try/catch` 检测 `instanceof AuthInvalidatedError` → 填上述字段。Agent loop 在 stream 收尾时若 `errorReason === "authInvalidated"`：

1. 发 `ui.error { code: -32003, message }`
2. 同时发 `provider.statusChanged { providerId, state: "unauthenticated", reason: "authInvalidated", message }`

`llm/` 包仍不 import dispatcher——典型的"信息上抛、决策上提"。agent loop 是唯一允许把 llm 错误投影到 RPC 的地方。

### Method 与错误常量

`AOSRPCSchema/Messages.swift` 与 `sidecar/src/rpc/rpc-types.ts` 同步新增：

```
RPCMethod.providerStatus         = "provider.status"
RPCMethod.providerStartLogin     = "provider.startLogin"
RPCMethod.providerCancelLogin    = "provider.cancelLogin"
RPCMethod.providerLoginStatus    = "provider.loginStatus"
RPCMethod.providerStatusChanged  = "provider.statusChanged"

RPCErrorCode.loginInProgress     = -32200
RPCErrorCode.loginCancelled      = -32201
RPCErrorCode.loginTimeout        = -32202
RPCErrorCode.unknownProvider     = -32203
RPCErrorCode.loginNotConfigured  = -32204
```

## Cancel / abort 硬契约

```ts
// sidecar/src/auth/loopback.ts
interface LoopbackHandle {
  port: number;
  /// Resolves with validated `code` query param, or rejects on
  /// state mismatch / abort / handle close.
  codePromise: Promise<string>;
  /// Idempotent. Closes server, rejects pending codePromise with
  /// AbortError if not yet resolved.
  close(): void;
}
function startCallbackServer(opts: {
  expectedState: string;
  signal: AbortSignal;
}): Promise<LoopbackHandle>;

// sidecar/src/llm/auth/oauth/chatgpt-plan.ts —— 改签名
exchangeCode(opts: ExchangeOptions & { signal?: AbortSignal }): Promise<TokenSet>;
refresh(refreshToken: string, opts?: { signal?: AbortSignal }): Promise<TokenSet>;
// fetch() 透传 signal
```

`LoginSession` 持有 `AbortController`。三条触发取消的路径：

| 触发 | 行为 |
|---|---|
| `provider.cancelLogin` | `controller.abort()` → loopback close → `codePromise` reject AbortError → 后台 task catch → 发 `loginStatus { failed, errorCode: -32201 }` |
| 5min timer | 同上，errorCode = `-32202` |
| Sidecar 进程退出 | OS 自动回收 fd / port |

cancel 已经写盘成功的 session 返 `{ cancelled: false }`，session 状态保持 `success`。

## 模块布局

### Sidecar

```
sidecar/src/
  auth/                                # 新建：runtime 层
    runtime.ts                         # LoginSession 类、startLogin / cancelLogin / status
    loopback.ts                        # startCallbackServer（含 abort 契约）
    providers.ts                       # 已知 provider 元数据 + 状态查询（纯 sync）
    register.ts                        # 把 provider.* request 注册到 Dispatcher
    cli.ts                             # 独立 CLI 入口，调 runtime 模块
  llm/auth/oauth/
    chatgpt-plan.ts                    # 删 startCallbackServer 与 runLoginCLI；
                                       # 仅留 buildAuthorizeUrl / exchangeCode / refresh / readChatGPTToken
                                       # 新增 AuthInvalidatedError；refresh 失败时 rename .invalid
  agent/loop.ts                        # 收尾时检查 errorReason，必要时发 statusChanged
```

依赖方向（强契约）：

```
auth/runtime  →  auth/loopback
              →  llm/auth/oauth/chatgpt-plan  （仅纯函数）
              →  llm/auth/oauth/storage
llm/auth/oauth/chatgpt-plan  →  llm/auth/oauth/storage
```

`auth/runtime` 不被 `llm/` 引用；`llm/auth/env-api-keys` 不引用 `auth/runtime`。

### Shell

```
Sources/AOSRPCSchema/
  Provider.swift                       # ProviderInfo / 5 个 params/results / login state enum
  Messages.swift                       # RPCMethod / RPCErrorCode 新增常量

Sources/AOSShell/
  Provider/
    ProviderService.swift              # @Observable，registerHandlers + queryStatus + startLogin
  Notch/Components/
    OnboardPanelView.swift             # opened 态 onboard UI
  Notch/NotchView.swift                # 改：opened 分支根据 providerService.hasReadyProvider 分流
  Notch/NotchViewModel.swift           # 改：注入 providerService 引用
  App/CompositionRoot.swift            # 改：构造 ProviderService、mount 后异步 refreshStatus

Tests/AOSShellTests/
  ProviderServiceTests.swift           # 状态机 + notification handler + invalidated 路径
Tests/AOSRPCSchemaTests/
  RoundtripTests.swift                 # 新增 provider.* fixture 测试
tests/rpc-fixtures/
  provider.status.json
  provider.startLogin.json
  provider.cancelLogin.json
  provider.loginStatus.json
  provider.statusChanged.json
```

`ProviderService`（注意 `.unknown` 是 **Shell 本地 enum**，不出现在 wire）：

```swift
@MainActor
@Observable
public final class ProviderService {
    public enum State: Sendable, Equatable {
        case unknown            // 启动前 / refresh 未完成
        case ready
        case unauthenticated
    }

    public struct Provider: Equatable, Sendable {
        public let id: String
        public let name: String
        public var state: State
    }

    /// 启动种子：保证 onboard 卡片永不空白。
    public private(set) var providers: [Provider] = [
        Provider(id: "chatgpt-plan",
                 name: "Codex (ChatGPT) Subscription",
                 state: .unknown)
    ]
    public private(set) var statusLoaded: Bool = false
    public private(set) var loginSession: LoginSession?

    /// `unknown` 时不算 ready。statusLoaded 守住"未查询完不分流"。
    public var hasReadyProvider: Bool {
        statusLoaded && providers.contains { $0.state == .ready }
    }

    public struct LoginSession: Equatable, Sendable {
        public let loginId: String
        public let providerId: String
        public var state: ProviderLoginState
        public var message: String?
    }

    public func refreshStatus() async              // 调 provider.status
    public func startLogin(providerId: String) async   // 调 provider.startLogin + NSWorkspace.open
    public func cancelLogin() async                // 调 provider.cancelLogin
    // notification 处理：loginStatus 更新 loginSession；statusChanged 局部更新 providers[i].state
}
```

成功路径：`loginStatus.success` → 显示 600ms "登录成功 ✓" → ProviderService 调 `refreshStatus()` → `loginSession = nil` → `OpenedPanelView` 自动接管。

`unknown` 状态的卡片渲染为 spinner + "正在检查"，**不允许点击**，避免在状态未知时发起 PKCE。

### CompositionRoot 顺序

保留现状的"先 mount UI、再异步握手"模式：

```
1. SenseStore.start()
2. spawn sidecar
3. 构造 RPCClient → 启动 reader
4. 构造 ProviderService（注册 handlers，不发 RPC）
5. 构造 AgentService
6. mountWindow()                    ← 立刻有 UI（providers seed = unknown，渲染 onboard 加载态）
7. await client.awaitHandshake()
8. await providerService.refreshStatus()   ← 失败仅日志；providers 全 unknown 时 onboard 显示"无法连接 sidecar，重试"
9. EventMonitors.start()
```

## NotchView 分流

`OpenedPanelView` 维持现状只负责 input 面板。`NotchView.content` 在 opened 分支分流，避免 OpenedPanelView 自引用：

```swift
if viewModel.status == .opened {
    if viewModel.providerService.hasReadyProvider {
        OpenedPanelView(...)
    } else {
        OnboardPanelView(providerService: viewModel.providerService)
    }
}
```

`OnboardPanelView` 子状态：

| 子状态 | 触发 | 渲染 |
|---|---|---|
| 加载中 | `statusLoaded == false` | 标题 + 单卡片显示 spinner，不可点 |
| 卡片列表 | `loginSession == nil && statusLoaded` | 标题 "选择登录方式"；卡片可点 |
| 进行中 | `loginSession.state ∈ {awaitingCallback, exchanging}` | 卡片高亮，文案 "已在浏览器中打开，请完成授权" / "正在校验"，spinner，"取消" 按钮 |
| 失败 | `loginSession.state == .failed` | 红色 + 错误简述，"重试" / "取消" |
| 成功 | `loginSession.state == .success` | 绿色对勾 + "登录成功"（600ms 后自动消失） |

## 取消 / 超时 / 错误细则

| 场景 | 行为 |
|---|---|
| 用户点取消 | Shell 调 `provider.cancelLogin`；sidecar abort → loopback close → 发 `loginStatus { failed, errorCode: -32201 }` |
| 5min 超时 | Sidecar 自动 abort；`loginStatus { failed, errorCode: -32202 }` |
| 浏览器跳回 state mismatch | Sidecar HTTP 回 400 + 关 loopback；`loginStatus { failed, message: "state mismatch" }` |
| token endpoint 非 2xx | `loginStatus { failed, message: "token exchange failed: …" }`；不重试 |
| 用户关闭 panel（ESC） | login session **不取消**；session 跑到自然结束，重新打开 panel 仍能看到进度 |
| sidecar 崩溃重启 | session 丢失，Shell 重新查 status |
| 运行期 refresh 失败 | runtime rename `.invalid`；agent loop 发 `ui.error -32003` + `provider.statusChanged unauthenticated authInvalidated`；ProviderService 翻状态，next opened 进 onboard |

## 实现顺序

1. **Plan 与设计文档**（本文件 + `llm-provider.md` + `rpc-protocol.md` 修订）
2. **RPC schema**：Swift `Provider.swift`、TS rpc-types、新 method/error 常量、5 个 fixture、Swift roundtrip + TS roundtrip 测试
3. **Sidecar 抽离 loopback**：`auth/loopback.ts` + abort 契约；`chatgpt-plan.ts` 改 import 与签名（exchangeCode/refresh 加 signal、refresh 失败 rename .invalid、新增 AuthInvalidatedError）；既有测试不变绿
4. **Sidecar runtime + register**：`auth/providers.ts` + `auth/runtime.ts` + `auth/register.ts` + `auth/cli.ts`；`index.ts` wire-up；新单测覆盖 status / startLogin / cancel / 并发拒绝 / loginNotConfigured / typed error 传播
5. **Sidecar agent loop**：检查 `errorReason === "authInvalidated"` → 发 `provider.statusChanged`；单测覆盖
6. **Shell ProviderService**：注册 handler、查 status、启动 login、取消、状态机；单测包括 invalidated 路径
7. **OnboardPanelView + NotchView 分流**
8. **CompositionRoot**：插入 ProviderService 初始化与异步 refreshStatus（保留 mount-first）
9. **构建验证**：`swift build` + `bun test`；手工跑 `bun run sidecar/src/auth/cli.ts` 验证 CLI 路径未受抽离影响

## 验证标准

- 启动期：删除 `chatgpt.json` → 启动 → opened 面板进 onboard；写入合法 token → opened 面板正常
- 启动期 schema 损坏：写入 `{"foo":1}` → onboard
- 运行期失效：mock refresh endpoint 返 401 → 触发 `agent.submit` → 期望按序：`ui.error -32003` + `provider.statusChanged { unauthenticated, authInvalidated }` + ProviderService 翻状态 + `chatgpt.json` 已 rename 到 `.invalid`
- `provider.status`：纯 sync，单测断言不发任何 fetch
- `provider.startLogin`：返回 URL 含正确 PKCE challenge / state；同时 sidecar listen loopback port
- 模拟 callback → 按序：`awaitingCallback` → `exchanging` → `success` → 后续 `provider.status` 返回 `ready`
- 第二次 `startLogin` 在前一次未完成时返回 `ErrLoginInProgress`（JSON-RPC error response，不发 notification）
- `CHATGPT_PLAN_CLIENT_ID == "TBD"` → `startLogin` 直接返回 `ErrLoginNotConfigured`
- `cancelLogin`：触发 `loginStatus { failed, errorCode: -32201 }`；后台 task 不再写盘；loopback fd / port 已释放
- 5min 超时：fake timer 跑过 5min → `loginStatus { failed, errorCode: -32202 }`
- 方向约束：`dispatcher.notify("provider.status", {})` 抛 programmer error；`dispatcher.notify("provider.loginStatus", {...})` 正常发出
- byte-equal fixture roundtrip：5 个 provider fixture 在 Swift 和 TS 两端都过
- CLI 路径 `bun run sidecar/src/auth/cli.ts` 仍可独立完成 PKCE
- ProviderService 启动种子：`hasReadyProvider == false`、卡片仍可见（spinner 态），不闪空白
