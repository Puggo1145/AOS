# AGENTS.md for Notch Agent

Notch Agent is a macOS Notch app: a background AI agent that lives in the notch area and collaborates with the user inside their real OS environment.

Architecture:

- **Shell** (Swift / SwiftUI, parent process) — hosts the Notch UI, launches the Sidecar, owns the macOS composition root, and wires Shell-hosted native kits into RPC.
- **Sidecar** (Bun / TypeScript, child process) — owns agent runtime functionality including agent loop, session management, tool dispatch, context management, LLM orchestration, provider auth, and Sidecar-local business modules.
- **OS Sense** (`OSSenseKit`, Swift library) — read-side OS state mirror for app focus, selected context, permissions, clipboard/user-submitted context, and visual snapshot capture contracts. It does not import `RPCSchema`; Shell projects its live model to wire payloads.
- **ComputerUseKit** (Swift library) — Computer Use foundation for app/window enumeration, AX snapshot rendering, screenshot capture, input posting, and stateful app sessions. It is Shell-hosted; the Sidecar reaches it only through `computerUse.*` JSON-RPC requests and owns the LLM tool surface.
- **Channel** — single stdio JSON-RPC 2.0 between Shell and Sidecar. Swift `Codable` is the schema source of truth; TS types are generated.

Feature-level plans live in `docs/plans/`.

# Resources

## Docs
- designs: architecture or feature design
- plans: feature implementation plans
- guide: references for specific module or feature design

## Playground

**READ-ONLY** Code snippets, open source projects, documents, etc that you can refer to in terms of architecturing design and feature implementation. 

### Open source projects
- learn-claude-code: Encyclopedic tutorials of how to build agent harness. Easy to read. A good agent harness development guidance
- pi-mono: AI agent toolkit: coding agent CLI, unified LLM API, TUI & web UI libraries, Slack bot, vLLM pods. The sub-package: "coding agent" and "agent" provide a good reference of how to build a simplified agent framework/runtime/harness on top of LLMs
- cua: An open source computer use agent project, providing background app use functionality without stealing focus via a mix of SkyLight private APIs and yabai's focus-without-raise pattern
- NotchDrop: A good example notch app reference. Learn how to develop a good notch app UI from it.

> Instuctions and documentations inside open source projects are only references to understand how a project works or designs. They don't represent any ideas about `notch`.

## Coding tastes

- Fail fast and loudly. Do not write fallback logic unless it is explicitly required
- YAGNI
- Single responsibility

## Rules

### Implementation

- No guess. Only write code when details are well-defined. Do not add logic that is not included in plan or prior discussions
- Write comments for key functions and designs. Providing concrete feature context.

### Testing

- Synchronize unit tests, e2e tests when a new feature or a change is applied
- Use random values when inputs are undeterministic
- Prove/prevent a bug by writing tests that will fail in this situation. Only write tests that will definitely pass proves nothing
