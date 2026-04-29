// session.* RPC handlers — Shell→Bun requests + Bun→Shell notifications.
//
// Per docs/designs/session-management.md. The dispatcher's
// `SESSION_METHOD_KINDS` table guards direction; this module is the only
// place that wires the manager's SessionEvent sink to the wire protocol.

import { RPCErrorCode, RPCMethod, type SessionActivateParams, type SessionActivateResult, type SessionCreateParams, type SessionCreateResult, type SessionListResult } from "../../rpc/rpc-types";
import { Dispatcher, RPCMethodError } from "../../rpc/dispatcher";
import { Conversation } from "../conversation";
import type { SessionManager } from "./manager";

export function registerSessionHandlers(dispatcher: Dispatcher, manager: SessionManager): void {
  // Bridge manager events → wire notifications. Single edge from internal
  // SessionEvent type to RPC; everywhere else (loop.ts, etc.) goes through
  // the manager API rather than calling `dispatcher.notify` for session.*.
  manager.setSink((event) => {
    switch (event.kind) {
      case "created":
        dispatcher.notify(RPCMethod.sessionCreated, { session: event.session });
        return;
      case "activated":
        dispatcher.notify(RPCMethod.sessionActivated, { sessionId: event.sessionId });
        return;
      case "listChanged":
        dispatcher.notify(RPCMethod.sessionListChanged, {});
        return;
    }
  });

  dispatcher.registerRequest(RPCMethod.sessionCreate, async (raw): Promise<SessionCreateResult> => {
    const params = (raw ?? {}) as SessionCreateParams;
    const session = manager.create({ title: params.title });
    return { session: session.toListItem() };
  });

  dispatcher.registerRequest(RPCMethod.sessionList, async (): Promise<SessionListResult> => {
    return {
      activeId: manager.activeId,
      sessions: manager.list(),
    };
  });

  dispatcher.registerRequest(RPCMethod.sessionActivate, async (raw): Promise<SessionActivateResult> => {
    const { sessionId } = (raw ?? {}) as SessionActivateParams;
    if (typeof sessionId !== "string") {
      throw new RPCMethodError(RPCErrorCode.invalidParams, "session.activate requires { sessionId }");
    }
    const session = manager.get(sessionId);
    if (!session) {
      throw new RPCMethodError(RPCErrorCode.unknownSession, `unknown sessionId: ${sessionId}`);
    }
    manager.activate(sessionId);
    const snapshot = session.conversation.turns.map((t) => Conversation.toWire(t));
    // s03: hydrate the Shell's todo panel for the freshly visible session.
    // Sent regardless of whether the list is empty — the Shell mirror uses
    // an empty list to clear any stale state from the previous session.
    dispatcher.notify(RPCMethod.uiTodo, {
      sessionId: session.id,
      items: session.todos.snapshot(),
    });
    return { snapshot };
  });
}
