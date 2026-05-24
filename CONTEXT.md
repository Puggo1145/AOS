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

### Computer Use Tool Surface

The Sidecar-owned LLM tool surface that exposes approved Computer Use
Foundation capabilities to the Agent Turn runtime. Its public registration
interface is stable, while its internal Modules own catalog definitions, Shell
RPC adapter calls, event validation, result rendering, and screenshot
coordinate state.

### File Tool Path Policy

The Sidecar-owned path semantics Module for file tools such as `read`, `write`,
and `update`. It centralizes how model-supplied paths become absolute filesystem
paths: absolute paths are normalized, relative paths resolve against the
Sidecar cwd, and bare `~` or `~/...` resolve to the user's home directory.
File tools are not sandboxed; the system prompt nudges scratch work toward the
Notch Agent workspace.

### RPC Method Catalog

The Sidecar-local Method Semantics catalog: one entry per RPC method covering
method direction, request vs notification kind, inbound handler timeout, and
dispatcher fast-path status. It complements the wire schema in `rpc-types.ts`.

### Runtime Wire Projection

The Sidecar Adapter that translates runtime Modules such as Session and
Conversation Transcript into Shell-visible RPC schema shapes. Runtime Modules
do not own wire field names; RPC handlers and notifications call this Adapter
at the dispatch edge.

### Agent Test Harness

The shared test utility layer for Agent Turn tests. It provides fake models,
assistant messages, capturing dispatchers, session bootstrap, and async flush
helpers so tests describe behavior instead of rebuilding Sidecar runtime
plumbing.
