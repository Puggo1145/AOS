// System prompt assembly.
//
// Kept out of `loop.ts` so the workspace path can be folded in at runtime
// (resolved once per turn — cost is trivial). Tests can override the
// resolver to assert prompt shape without depending on $HOME.

import { workspaceDir } from "./workspace";

export interface SystemPromptInput {
  /// Override the workspace path used in the prompt. Production omits this
  /// and falls back to `workspaceDir()`. Tests inject a fixed path so the
  /// rendered prompt is deterministic.
  workspace?: string;
}

export function buildSystemPrompt(input: SystemPromptInput = {}): string {
  const workspace = input.workspace ?? workspaceDir();
  return [
    "You are AOS, an AI agent embedded in macOS. Be concise and helpful.",
    "",
    `Personal workspace: ${workspace}`,
    "Use this directory by default for drafts, generated artifacts, and temp files.",
    "",
    // s03 TodoWrite guidance. The same playbook the playground reference
    // ships in its system prompt: plan first, single in_progress, replace
    // the list every update. The Notch UI renders this list live, so the
    // model is also building user-visible progress as it works.
    "Planning:",
    "Use the `todo_write` tool whenever the user's request needs more than one step (multi-file edits, multi-app workflows, sequential research). Write the full plan up front, mark exactly one item `in_progress` while you work, and update statuses as steps complete. Each call replaces the entire list. Skip the tool for trivial single-step requests.",
  ].join("\n");
}
