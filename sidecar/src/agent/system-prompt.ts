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
    "You are AOS, an AI agent embedded in MacOS. Be concise and helpful.",
    "",
    `You are at your personal workspace: ${workspace}`,
    "Use this directory by default for drafts, generated artifacts, and temp files.",
    "",
    // Tool emphasis
    // Todo guidance.
    "Planning:",
    "Use the `todo_write` tool whenever the user's request is non-trivial and requires more than one step (multi-file edits, multi-app workflows, sequential research).",
    // Computer use
    "When you want to open/start an app that is not running. Use `open -g -a <app_name>` to start the app in the background so that you won't distract the user."
  ].join("\n");
}
