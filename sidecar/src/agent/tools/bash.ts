// Bash tool — execute shell commands via `Bun.spawn`.
//
// Design choices:
//   - cwd is intentionally NOT pinned. AOS is an OS-level helper, not a
//     sandbox; the model uses `cd` inside its command if it needs a
//     specific directory. The system prompt nudges it toward
//     `~/.aos/workspace/` for scratch work.
//   - `bash -lc <cmd>` so the model can chain commands, use pipes, and
//     pick up the user's shell rc (PATH, conda, asdf, etc.).
//   - Output is captured in full, then tail-truncated for the LLM
//     payload. Full output stays available in `details.fullOutput` for
//     future Shell-side rendering — we don't write to /tmp this round
//     (YAGNI: nothing reads from disk yet).
//   - Timeout and turn-cancellation share one AbortController: whichever
//     fires first kills the subprocess.

import type { ToolHandler, ToolExecContext, ToolExecResult } from "./types";

const MAX_OUTPUT_BYTES = 50_000;
const MAX_OUTPUT_LINES = 200;

/// Default hard timeout when the model omits `timeout`. AOS runs as a
/// background OS-level helper; an unbounded `tail -f` / `sleep 999` would
/// pin the turn forever. 120s is generous for typical commands and short
/// enough that a runaway is recoverable without manual intervention.
const DEFAULT_TIMEOUT_SECONDS = 120;
/// Hard ceiling on user-supplied `timeout`. The model can ask for a longer
/// budget for genuine long-runners, but not unbounded — same reliability
/// reasoning as the default.
const MAX_TIMEOUT_SECONDS = 600;

interface BashArgs {
  command: string;
  /// Hard timeout in seconds. Omit to use the default (120s); values are
  /// clamped to [1, 600]. Non-finite / non-positive values are rejected.
  timeout?: number;
}

interface BashDetails {
  exitCode: number | null;
  signal: NodeJS.Signals | null;
  durationMs: number;
  fullOutput: string;
  truncated: boolean;
  truncatedLines?: number;
  truncatedBytes?: number;
}

export function createBashTool(): ToolHandler<BashArgs, BashDetails> {
  return {
    spec: {
      name: "bash",
      description:
        `Execute a bash command via \`bash -lc\`. Returns combined stdout+stderr. ` +
        `Output is tail-truncated to the last ${MAX_OUTPUT_LINES} lines or ${MAX_OUTPUT_BYTES / 1000}KB ` +
        `(whichever hits first). The current working directory is NOT pinned to the AOS workspace — ` +
        `use \`cd\` inside the command when you need a specific directory.`,
      parameters: {
        type: "object",
        properties: {
          command: {
            type: "string",
            description: "Bash command to execute. Use `cd` to switch directories.",
          },
          timeout: {
            type: "number",
            description: `Hard timeout in seconds. Omit for the default (${DEFAULT_TIMEOUT_SECONDS}s). Clamped to [1, ${MAX_TIMEOUT_SECONDS}].`,
          },
        },
        required: ["command"],
      },
    },
    execute: (args, ctx) => runBash(args, ctx),
  };
}

async function runBash(args: BashArgs, ctx: ToolExecContext): Promise<ToolExecResult<BashDetails>> {
  const startedAt = Date.now();

  // Resolve effective timeout. The JSON-schema validator does not enforce
  // numeric bounds, so the runtime is the only place these invariants hold:
  //   - missing/undefined → DEFAULT_TIMEOUT_SECONDS
  //   - non-finite or ≤ 0 → reject as a tool error so the model can self-correct
  //   - over MAX_TIMEOUT_SECONDS → clamp (still honor the model's intent to
  //     allow a long-running command, just not unbounded)
  let effectiveTimeout: number;
  if (args.timeout === undefined) {
    effectiveTimeout = DEFAULT_TIMEOUT_SECONDS;
  } else if (!Number.isFinite(args.timeout) || args.timeout <= 0) {
    return {
      content: [
        {
          type: "text",
          text: `bash: invalid timeout ${args.timeout}; must be a positive finite number of seconds (≤ ${MAX_TIMEOUT_SECONDS}).`,
        },
      ],
      isError: true,
    };
  } else {
    effectiveTimeout = Math.min(args.timeout, MAX_TIMEOUT_SECONDS);
  }

  // Timeout + turn cancellation funnel into one signal. The combined
  // controller is what the spawn listens on; either source aborts it.
  const combined = new AbortController();
  const onParentAbort = () => combined.abort();
  ctx.signal.addEventListener("abort", onParentAbort, { once: true });

  const timeoutHandle: ReturnType<typeof setTimeout> = setTimeout(
    () => combined.abort(),
    effectiveTimeout * 1000,
  );

  let proc: ReturnType<typeof Bun.spawn> | undefined;
  try {
    proc = Bun.spawn(["bash", "-lc", args.command], {
      stdout: "pipe",
      stderr: "pipe",
      signal: combined.signal,
    });

    // Read both streams concurrently. Bun's spawn pipes are ReadableStream<Uint8Array>;
    // `Response` is the simplest way to drain them to text without manual
    // chunk concat.
    const [stdoutText, stderrText, exitCode] = await Promise.all([
      new Response(proc.stdout as ReadableStream).text(),
      new Response(proc.stderr as ReadableStream).text(),
      proc.exited,
    ]);

    const combinedOutput = joinStreams(stdoutText, stderrText);
    const truncated = truncateTail(combinedOutput);
    const durationMs = Date.now() - startedAt;

    const aborted = combined.signal.aborted;
    const timedOut = aborted && !ctx.signal.aborted;

    let displayText = truncated.text || "(no output)";
    if (truncated.truncated) {
      const note = `[truncated: ${truncated.truncatedLines ?? 0} earlier lines / ${truncated.truncatedBytes ?? 0} bytes omitted]`;
      displayText = `${note}\n${displayText}`;
    }

    const details: BashDetails = {
      exitCode,
      signal: null,
      durationMs,
      fullOutput: combinedOutput,
      truncated: truncated.truncated,
      truncatedLines: truncated.truncatedLines,
      truncatedBytes: truncated.truncatedBytes,
    };

    if (timedOut) {
      // Timeout path — surface as an error result so the model can choose
      // to retry with a longer timeout or a different command.
      const msg = `[timed out after ${effectiveTimeout}s]\n${displayText}`;
      return { content: [{ type: "text", text: msg }], details, isError: true };
    }

    if (ctx.signal.aborted) {
      // Turn cancellation — same shape as timeout but worded differently
      // so the model can distinguish in trace.
      const msg = `[cancelled by user]\n${displayText}`;
      return { content: [{ type: "text", text: msg }], details, isError: true };
    }

    if (exitCode !== 0) {
      const msg = `${displayText}\n[exit code ${exitCode}]`;
      return { content: [{ type: "text", text: msg }], details, isError: true };
    }

    return { content: [{ type: "text", text: displayText }], details, isError: false };
  } finally {
    clearTimeout(timeoutHandle);
    ctx.signal.removeEventListener("abort", onParentAbort);
  }
}

function joinStreams(stdout: string, stderr: string): string {
  if (stdout && stderr) return `${stdout}\n${stderr}`;
  return stdout || stderr;
}

interface TruncationResult {
  text: string;
  truncated: boolean;
  truncatedLines?: number;
  truncatedBytes?: number;
}

/// Tail truncation: keep the last MAX_OUTPUT_LINES lines, then trim from the
/// front if still over MAX_OUTPUT_BYTES. The model usually wants the most
/// recent output (errors, prompts, last log line), not the head.
function truncateTail(text: string): TruncationResult {
  if (!text) return { text: "", truncated: false };
  const lines = text.split("\n");
  let truncatedLines = 0;
  let kept = lines;
  if (lines.length > MAX_OUTPUT_LINES) {
    truncatedLines = lines.length - MAX_OUTPUT_LINES;
    kept = lines.slice(-MAX_OUTPUT_LINES);
  }
  let out = kept.join("\n");
  let truncatedBytes = 0;
  const bytes = Buffer.byteLength(out, "utf-8");
  if (bytes > MAX_OUTPUT_BYTES) {
    // Trim from the front, byte-aware.
    const buf = Buffer.from(out, "utf-8");
    const tail = buf.subarray(buf.length - MAX_OUTPUT_BYTES);
    truncatedBytes = bytes - MAX_OUTPUT_BYTES;
    out = tail.toString("utf-8");
  }
  if (truncatedLines > 0 || truncatedBytes > 0) {
    return { text: out, truncated: true, truncatedLines, truncatedBytes };
  }
  return { text: out, truncated: false };
}
