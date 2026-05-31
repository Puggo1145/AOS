// Silent-progress ambient provider — nudges the model to give the user a
// status update once it has run a long stretch of tool calls without saying
// anything in plain text.
//
// Why this exists: long autonomous tool sequences (planning, multi-step
// computer-use workflows, recursive code searches) routinely chain dozens
// of tool calls before the model emits any user-visible reply. To the user
// the Notch shows tool activity but no narration — they cannot tell whether
// the agent is on track, stuck, or about to do the wrong thing. The hard
// `MAX_CONSECUTIVE_TOOL_ROUNDS` cap in the loop catches runaways; this
// provider catches the much more common "model is fine but went silent"
// case much earlier and asks it to surface progress before continuing.
//
// Threshold = 10. Below 10 we stay out of the prompt entirely (returning
// `null` so the registry omits the wrapper). At or above 10 we inject one
// short reminder; the model is then expected to send a brief status reply
// in its next round (which resets the counter via the loop's `spokeThisRound`
// path) and resume work after.

import type { AmbientProvider } from "../provider";
import type { Session } from "../../session/session";

const SILENT_PROGRESS_REMIND_AT = 10;

export const silentProgressAmbientProvider: AmbientProvider = {
	name: "progressReminder",
	render(session: Session): string | null {
		const n = session.silentToolRounds;
		if (n < SILENT_PROGRESS_REMIND_AT) return null;
		return (
			`You have just executed ${n} consecutive tool calls without sending any reply text to the user. ` +
			`Pause and tell the user a short status update on what you've done so far and what's next, ` +
			`then continue your work.`
		);
	},
};
