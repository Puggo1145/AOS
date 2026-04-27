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
  ].join("\n");
}
