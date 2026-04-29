// TodoManager — validation and rendering invariants.
//
// The manager is the entry the `todo_write` tool calls into; the loop trusts
// it to enforce shape (one in_progress / max 20 / closed status enum) so a
// schema-valid wire payload still can't smuggle an inconsistent plan into
// the model's view. These tests pin the policy directly.

import { test, expect } from "bun:test";
import { TodoManager } from "../src/agent/todos/manager";

test("update accepts a valid list and renders with status markers", () => {
  const m = new TodoManager();
  const out = m.update([
    { id: "1", text: "read", status: "completed" },
    { id: "2", text: "write", status: "in_progress" },
    { id: "3", text: "test", status: "pending" },
  ]);
  expect(m.items).toHaveLength(3);
  // Render shape mirrors the playground: marker glyph + #id + text, then
  // a trailing progress count. Anything else means the wire shape the
  // model sees has drifted from spec.
  expect(out).toContain("[x] #1: read");
  expect(out).toContain("[>] #2: write");
  expect(out).toContain("[ ] #3: test");
  expect(out).toContain("(1/3 completed)");
});

test("update rejects multiple in_progress items", () => {
  const m = new TodoManager();
  expect(() =>
    m.update([
      { id: "1", text: "a", status: "in_progress" },
      { id: "2", text: "b", status: "in_progress" },
    ]),
  ).toThrow(/Only one task can be in_progress/);
  // Rejection must be all-or-nothing — a partial write would corrupt the
  // model's view of its own plan.
  expect(m.items).toHaveLength(0);
});

test("update rejects more than 20 items", () => {
  const m = new TodoManager();
  const big = Array.from({ length: 21 }, (_, i) => ({
    id: String(i + 1),
    text: `t${i + 1}`,
    status: "pending" as const,
  }));
  expect(() => m.update(big)).toThrow(/Too many todos/);
});

test("update rejects unknown status", () => {
  const m = new TodoManager();
  expect(() =>
    m.update([{ id: "1", text: "x", status: "blocked" }]),
  ).toThrow(/invalid status/);
});

test("update rejects empty text", () => {
  const m = new TodoManager();
  expect(() => m.update([{ id: "1", text: "   ", status: "pending" }])).toThrow(
    /text required/,
  );
});

test("update rejects duplicate ids — model is supposed to keep stable ids per item", () => {
  const m = new TodoManager();
  expect(() =>
    m.update([
      { id: "1", text: "a", status: "pending" },
      { id: "1", text: "b", status: "pending" },
    ]),
  ).toThrow(/duplicate id/);
});

test("whole-list semantics: each update replaces the prior list verbatim", () => {
  const m = new TodoManager();
  m.update([{ id: "1", text: "step", status: "in_progress" }]);
  m.update([
    { id: "a", text: "new plan", status: "pending" },
    { id: "b", text: "also new", status: "pending" },
  ]);
  expect(m.items.map((i) => i.id)).toEqual(["a", "b"]);
});

test("subscribe fires after every update with the latest snapshot", () => {
  const m = new TodoManager();
  const seen: number[] = [];
  m.subscribe((items) => seen.push(items.length));
  m.update([{ id: "1", text: "a", status: "pending" }]);
  m.update([
    { id: "1", text: "a", status: "completed" },
    { id: "2", text: "b", status: "pending" },
  ]);
  expect(seen).toEqual([1, 2]);
});

test("clear empties the list and fires subscribers; second clear is a no-op", () => {
  const m = new TodoManager();
  m.update([{ id: "1", text: "a", status: "pending" }]);
  let fires = 0;
  m.subscribe(() => fires++);
  m.clear();
  m.clear(); // already empty — must NOT re-fire (avoids spurious ui.todo
              // notifications on a session that never had a plan).
  expect(m.items).toHaveLength(0);
  expect(fires).toBe(1);
});

test("hasOpenWork: empty plan and all-completed plan both report false", () => {
  const m = new TodoManager();
  expect(m.hasOpenWork()).toBe(false);
  m.update([
    { id: "1", text: "a", status: "completed" },
    { id: "2", text: "b", status: "completed" },
  ]);
  expect(m.hasOpenWork()).toBe(false);
  m.update([
    { id: "1", text: "a", status: "completed" },
    { id: "2", text: "b", status: "pending" },
  ]);
  expect(m.hasOpenWork()).toBe(true);
});
