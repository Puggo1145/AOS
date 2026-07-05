// Shared error-to-text helper.
//
// `catch (err)` gives us `unknown`; most call sites just want the human
// message for logging or wire errors. `Error` instances carry a `.message`;
// anything else (a thrown string, a plain object, a rejected non-Error) gets
// stringified as-is. Centralized so the same ternary isn't hand-rolled at
// every catch site.
export function errorText(err: unknown): string {
	return err instanceof Error ? err.message : String(err);
}
