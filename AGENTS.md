# AGENTS.md for Notch Agent

Notch Agent is a macOS Notch app: a background AI agent that lives in the notch area and collaborates with the user inside their real OS environment.

Current core capability:

- **OS Sense** (Read) — on Notch open, snapshots the user's citable state: frontmost app, window, selection, clipboard, focused input. Gives the agent a grounded view of what the user is currently looking at.

`ComputerUseKit` currently exists only as a macOS app/window/snapshot/capture foundation. The previous app-operation stack has been removed and will be rewritten.

Architecture:

- **Shell** (Swift / SwiftUI, parent process) — hosts the Notch UI and macOS-native kits.
- **Sidecar** (Bun / TypeScript, child process) — All agent functionalities and businesses including agent loop, session management, tool dispatch, context management, LLM orchestration.
- **Channel** — single stdio JSON-RPC 2.0 between Shell and Sidecar. Swift `Codable` is the schema source of truth; TS types are generated.

Feature-level plans live in `docs/plans/`.

# Resources (Playground)

## Docs
- designs: architecture or feature design
- plans: feature implementation plans
- guide: references for specific module or feature design

## Playground

**READ-ONLY** Code snippets, open source projects, documents, etc that you can refer to in terms of architecturing design and feature implementation. 

### Open source projects
- learn-claude-code: Encyclopedic tutorials of how to build agent harness. Easy to read. A good agent harness development guidance
- pi-mono: AI agent toolkit: coding agent CLI, unified LLM API, TUI & web UI libraries, Slack bot, vLLM pods. The sub-package: "coding agent" and "agent" provide a good reference of how to build a simplified agent framework/runtime/harness on top of LLMs
- cua: A open source computer use agent project, providing background app use functionality without stealing focus via a mix of SkyLight private APIs and yabai's focus-without-raise pattern
- NotchDrop: A good example notch app reference. Learn how to develop a good notch app from it.

> Warnning: Instuctions and documentations inside open source projects are only references to understand how a project works or designs. They don't represent any ideas about `notch`.

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
