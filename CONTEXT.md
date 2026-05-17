# Notch Agent Context

## Domain Terms

### Sidecar

The Bun / TypeScript child process that owns agent functionality: agent turn
execution, session management, tool dispatch, context management, LLM
orchestration, provider auth, and the Shell RPC peer.

### Shell

The Swift / SwiftUI parent process that hosts the Notch UI and macOS-native
kits. Shell owns OS Sense capture and the app/window/snapshot foundation.

### Agent Turn

One user submission inside a session. An Agent Turn starts with
`conversation.turnStarted`, streams model events and tool activity over `ui.*`,
mutates the Sidecar-owned conversation transcript, and ends as done, error, or
cancelled.

### Conversation Transcript

The LLM-visible history owned by a session. It contains user messages,
assistant messages, tool results, compaction prefaces, cancellation repair
markers, and screenshot pruning rules. It is the replay surface for later Agent
Turns.

### Computer Use Foundation

The Swift-only `ComputerUseKit` foundation for app enumeration, window
enumeration, AX snapshot rendering, screenshot capture, and snapshot state.
It is not exposed as an LLM-callable tool surface.

### RPC Method Catalog

The Sidecar-local catalog of method routing metadata: namespace direction,
request vs notification kind, inbound handler timeout, and dispatcher fast-path
status. It complements the wire schema in `rpc-types.ts`.

### Agent Test Harness

The shared test utility layer for Agent Turn tests. It provides fake models,
assistant messages, capturing dispatchers, session bootstrap, and async flush
helpers so tests describe behavior instead of rebuilding Sidecar runtime
plumbing.
