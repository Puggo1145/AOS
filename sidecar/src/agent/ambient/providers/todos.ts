// Todos ambient provider — projects the per-session TodoManager onto the
// rendered ambient block.
//
// Returns `null` when the plan is empty (model judged the task trivial,
// or no plan written yet). When items exist — pending, in_progress, or
// fully completed — the manager's existing `render()` is the inner
// content, byte-for-byte the same surface the model sees as the
// `todo_write` tool's return value. That alignment lets the model reason
// about its plan from a single rendering format rather than two
// near-identical ones.

import type { AmbientProvider } from "../provider";
import type { Session } from "../../session/session";

export const todosAmbientProvider: AmbientProvider = {
  name: "todos",
  render(session: Session): string | null {
    if (session.todos.items.length === 0) return null;
    return session.todos.render();
  },
};
