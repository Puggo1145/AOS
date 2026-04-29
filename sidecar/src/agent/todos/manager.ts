// TodoManager — per-session checklist state.
//
// Implements the s03 "TodoWrite" harness pattern: the model writes its plan
// to a structured store via the `todo_write` tool, the harness keeps the
// list in memory (no disk persistence), and the Notch UI renders the live
// list so the user can see progress.
//
// Per playground/learn-claude-code/design docs/s03-todo-write.md:
//   - Only one item may be `in_progress` at a time. The constraint forces
//     the model to commit to a focus instead of marking the whole plan
//     active at once.
//   - Whole-list semantics: each `todo_write` call replaces the list. The
//     model owns the canonical plan; the harness just validates and
//     stores. This avoids partial-edit races and matches how the upstream
//     reference behaves.
//   - Cap of 20 items prevents context blowup when the model gets carried
//     away producing micro-steps. The cap is recoverable — the validator
//     surfaces a `ToolUserError` so the model can retry with a tighter list.

export type TodoStatus = "pending" | "in_progress" | "completed";

export interface TodoItem {
  id: string;
  text: string;
  status: TodoStatus;
}

/// Subscriber fired after every successful `update`. Used by the loop to
/// project the latest list onto the wire as `ui.todo`.
export type TodoListener = (snapshot: TodoItem[]) => void;

const MAX_ITEMS = 20;
const VALID_STATUSES: ReadonlySet<TodoStatus> = new Set([
  "pending",
  "in_progress",
  "completed",
]);

export class TodoManager {
  private _items: TodoItem[] = [];
  private listeners = new Set<TodoListener>();

  get items(): readonly TodoItem[] {
    return this._items;
  }

  /// Snapshot copy. Callers freely mutate / iterate without aliasing the
  /// internal array.
  snapshot(): TodoItem[] {
    return this._items.map((it) => ({ ...it }));
  }

  /// Replace the entire list. Validation throws on bad shapes / quotas; the
  /// caller (the `todo_write` tool) catches and rethrows as a recoverable
  /// `ToolUserError` so the model can self-correct.
  ///
  /// Returns the human-readable rendering of the new state — exactly what the
  /// tool surfaces to the LLM as its result. Mirrors the playground: the
  /// model gets the rendered checklist back and uses it to verify its update
  /// landed.
  update(rawItems: unknown): string {
    if (!Array.isArray(rawItems)) {
      throw new Error("`items` must be an array");
    }
    if (rawItems.length > MAX_ITEMS) {
      throw new Error(`Too many todos: ${rawItems.length} (max ${MAX_ITEMS})`);
    }

    const validated: TodoItem[] = [];
    let inProgressCount = 0;
    const seenIds = new Set<string>();

    for (let i = 0; i < rawItems.length; i++) {
      const raw = rawItems[i];
      if (raw === null || typeof raw !== "object") {
        throw new Error(`Item #${i + 1}: must be an object`);
      }
      const r = raw as Record<string, unknown>;
      if (typeof r.id !== "string") {
        throw new Error(`Item #${i + 1}: id must be a string`);
      }
      if (typeof r.status !== "string") {
        throw new Error(`Item #${i + 1}: status must be a string`);
      }
      const id = r.id.trim();
      const text = typeof r.text === "string" ? r.text.trim() : "";
      const statusRaw = r.status.toLowerCase();

      if (id.length === 0) {
        throw new Error(`Item #${i + 1}: id must be non-empty`);
      }
      if (seenIds.has(id)) {
        throw new Error(`Item #${i + 1}: duplicate id "${id}"`);
      }
      seenIds.add(id);

      if (text.length === 0) {
        throw new Error(`Item "${id}": text required`);
      }

      if (!VALID_STATUSES.has(statusRaw as TodoStatus)) {
        throw new Error(
          `Item "${id}": invalid status "${statusRaw}" (expected pending | in_progress | completed)`,
        );
      }
      const status = statusRaw as TodoStatus;
      if (status === "in_progress") inProgressCount += 1;
      validated.push({ id, text, status });
    }

    if (inProgressCount > 1) {
      throw new Error("Only one task can be in_progress at a time");
    }

    this._items = validated;
    const snap = this.snapshot();
    for (const fn of this.listeners) fn(snap);
    return this.render();
  }

  /// Reset to empty. Called when the surrounding conversation is reset so a
  /// fresh session starts without inherited plan state. Listeners are fired
  /// so the wire / UI mirrors clear too.
  clear(): void {
    if (this._items.length === 0) return;
    this._items = [];
    const snap = this.snapshot();
    for (const fn of this.listeners) fn(snap);
  }

  subscribe(fn: TodoListener): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  /// Markdown-ish single-string rendering. Returned to the LLM after every
  /// `todo_write` call so the model can verify the new state. Format mirrors
  /// the playground reference: `[ ]` / `[>]` / `[x]` markers + a trailing
  /// progress count.
  render(): string {
    if (this._items.length === 0) return "No todos.";
    const lines: string[] = [];
    for (const item of this._items) {
      const marker = STATUS_MARKERS[item.status];
      lines.push(`${marker} #${item.id}: ${item.text}`);
    }
    const done = this._items.filter((i) => i.status === "completed").length;
    lines.push("", `(${done}/${this._items.length} completed)`);
    return lines.join("\n");
  }

  /// Whether the current list still has work to do. Used by the loop's nag
  /// logic to skip reminders when the plan is empty (model judged the task
  /// trivial) or fully completed (nothing to update).
  hasOpenWork(): boolean {
    return this._items.some((i) => i.status !== "completed");
  }
}

const STATUS_MARKERS: Record<TodoStatus, string> = {
  pending: "[ ]",
  in_progress: "[>]",
  completed: "[x]",
};
