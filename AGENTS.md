# AGENTS.md for AOS

The AOS (The Agent Operating System) project guideline for coding agents.

# Resources (Playground)

Inside the ./playground

**READ-ONLY** Code snippets, open source projects, documents, etc that you can refer to in terms of architecturing design and feature implementation. 

# Open source projects
- learn-claude-code: Encyclopedic tutorials of how to build agent harness. Easy to read. A good agent harness development guidance
- pi-mono: AI agent toolkit: coding agent CLI, unified LLM API, TUI & web UI libraries, Slack bot, vLLM pods. The sub-package: "coding agent" and "agent" provide a good reference of how to build a simplified agent framework/runtime/harness on top of LLMs
- claude-code-sourcemap: Claude Code source code v2.1.88. This is a complete code reference of how to build great agent harness.
- open-codex-computer-use: The open source implementation of computer use for AI Agents. Providing capabilities to manipulate Mac OS Applications directly without changing apps' focus. Full background operation.

## Important
Instuctions and documentations inside open source projects are only references to understand how a project works or designs. They don't represent any ideas about `aos`.

# Coding tastes

- Fail fast and loudly. Do not write fallback logic unless it is explicitly required
- YAGNI
- Single responsibility

# Rules

## Implementation

- No guess. Only write code when details are well-defined. Do not add logic that is not included in plan or prior discussions

## Testing

- Synchronize unit tests, e2e tests when a new feature or a change is applied
- Use random values when inputs are undeterministic
- Prove/prevent a bug by writing tests that will fail in this situation. Only write tests that will definitely pass proves nothing
