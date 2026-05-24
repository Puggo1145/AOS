// File Tool Path Policy — shared path semantics for read/write/update.
//
// File tools are intentionally not sandboxed. The model is nudged toward the
// Notch Agent workspace by the system prompt, but tool path resolution itself
// accepts absolute paths, sidecar-cwd-relative paths, and home-relative paths.

import { homedir } from "node:os";
import { resolve } from "node:path";

export const FILE_TOOL_PATH_POLICY_TEXT =
  "Path is NOT sandboxed — pass an absolute path, a relative path, or bare `~` or `~/...` for the user's home directory.";

export const FILE_TOOL_PATH_PARAMETER_DESCRIPTION =
  "Absolute path, relative path resolved against the sidecar cwd, or bare `~` or `~/...` for the user's home directory.";

/// Expand a leading home-directory `~` and normalize to an absolute path.
/// Other tilde prefixes, such as `~other/file`, are ordinary relative paths.
export function resolveFileToolPath(path: string): string {
  if (path.startsWith("~/") || path === "~") {
    return resolve(homedir(), path.slice(path === "~" ? 1 : 2));
  }
  return resolve(path);
}
