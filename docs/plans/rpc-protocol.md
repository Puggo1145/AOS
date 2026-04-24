# Shell ↔ Bun RPC 协议实现计划

设计依据：[docs/designs/rpc-protocol.md](../designs/rpc-protocol.md)

## 实现阶段

### Stage 1：协议骨架
- `AOSRPCSchema` Swift package 搭建，包含 Message / Hello / Error 基础类型
- `sidecar/src/rpc-types.ts` 手写对应 TS 类型
- `rpc-fixtures/` 初始 fixture + 两端 conformance test + CI
- Swift RPC codec（parse/serialize/dispatch，含 timeout 和并发模型）
- TS RPC codec
- `rpc.hello` + `rpc.ping` 双向跑通

### Stage 2：Agent 通道
- `agent.submit` / `agent.cancel` 接入（含 `citedContext` 字段）
- `ui.token` / `ui.status` / `ui.error` notification 流
- 用 stub agent（固定 echo）验证 happy path 和 cancel 路径

### Stage 3：Computer Use 通道
- `computerUse.*` 全部 8 个方法的 handler（Shell 侧）
- `stateId` 生命周期管理（Kit 内缓存 + TTL）
- Bun tool registry 对接 RPC client

### Stage 4：Settings + 端到端
- `settings.update` notification
- 端到端闭环：Notch 打开 → Shell 本地 snapshot → 用户勾选 + submit → agent 输出 → tool call → app 被操作

## 验证标准

- 协议一致性：Swift 和 TS 的 conformance roundtrip test 对所有 fixture 产出 byte-equal 结果
- 版本协商：构造 MAJOR 不匹配的 Bun 启动，Shell 必须拒绝并终止
- 流式：`agent.submit` 发出后 100ms 内收到首个 `ui.token`；`agent.cancel` 发出后 200ms 内收到 `ui.status: done`
- 方向约束：Bun 主动发 `agent.submit` → Shell 返回 `MethodNotFound`（反之亦然）
- 并发隔离：长耗时 `computerUse.getAppState` 进行中时 `rpc.ping` 仍在 1s 内响应
- 超时：给 Kit 注入 mock 延迟超过 timeout，handler 必须返回 `ErrTimeout`
- Payload 上限：构造超限 screenshot 必须返回 `ErrPayloadTooLarge`
- 隐私：未在 `citedContext` 中勾选的 sense 条目在 Bun 日志和内存里都不出现
