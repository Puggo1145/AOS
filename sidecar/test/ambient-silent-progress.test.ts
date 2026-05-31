// Silent-progress ambient provider — fires a "tell the user where you are"
// reminder once the in-flight turn has chained N consecutive tool rounds
// without any visible assistant text. Threshold is intentionally well below
// the hard `MAX_CONSECUTIVE_TOOL_ROUNDS` cap so the user gets a status
// update long before the loop has to bail.

import { test, expect } from "bun:test";
import { Session } from "../src/agent/session/session";
import { silentProgressAmbientProvider } from "../src/agent/ambient/providers/silent-progress";

function makeSession(): Session {
	return new Session({ id: "sess_test", createdAt: 0, title: "t" });
}

test("returns null when the silent-tool-round counter is below the threshold", () => {
	const s = makeSession();
	// Default 0 — no rounds yet.
	expect(silentProgressAmbientProvider.render(s)).toBeNull();
	s.setSilentToolRounds(9);
	expect(silentProgressAmbientProvider.render(s)).toBeNull();
});

test("emits a reminder mentioning the count at or above the threshold", () => {
	const s = makeSession();
	s.setSilentToolRounds(10);
	const out = silentProgressAmbientProvider.render(s);
	expect(out).not.toBeNull();
	expect(out!).toContain("10 consecutive tool calls");
	expect(out!.toLowerCase()).toContain("status update");

	s.setSilentToolRounds(17);
	const out2 = silentProgressAmbientProvider.render(s);
	expect(out2).not.toBeNull();
	expect(out2!).toContain("17 consecutive tool calls");
});

test("Session.setSilentToolRounds clamps negative values to 0", () => {
	const s = makeSession();
	s.setSilentToolRounds(-5);
	expect(s.silentToolRounds).toBe(0);
});
