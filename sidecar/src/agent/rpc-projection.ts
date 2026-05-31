// Agent runtime → RPC wire projection.
//
// Runtime Modules keep their own state-oriented Interface. This Adapter is
// the single place that translates those runtime objects into Shell-visible
// wire shapes.

import type { Conversation, ConversationTurn } from "./conversation";
import type { Session } from "./session/session";
import type { ConversationTurnWire, SessionListItem } from "../rpc/rpc-types";

export function conversationTurnToWire(
	turn: ConversationTurn,
): ConversationTurnWire {
	return {
		id: turn.id,
		prompt: turn.prompt,
		citedContext: turn.citedContext,
		reply: turn.reply,
		status: turn.status,
		errorMessage: turn.errorMessage,
		errorCode: turn.errorCode,
		startedAt: turn.startedAt,
	};
}

export function conversationSnapshotToWire(
	conversation: Conversation,
): ConversationTurnWire[] {
	return conversation.turns.map(conversationTurnToWire);
}

export function sessionToListItem(session: Session): SessionListItem {
	let turnCount = 0;
	let lastActivityAt = session.info.createdAt;
	for (const turn of session.conversation.turns) {
		if (turn.status === "done") turnCount += 1;
		if (turn.startedAt > lastActivityAt) lastActivityAt = turn.startedAt;
	}

	return {
		id: session.id,
		title: session.info.title,
		createdAt: session.info.createdAt,
		turnCount,
		lastActivityAt,
	};
}

export function sessionsToListItems(
	sessions: Iterable<Session>,
): SessionListItem[] {
	return Array.from(sessions, sessionToListItem);
}
