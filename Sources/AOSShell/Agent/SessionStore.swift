import Foundation
import AOSRPCSchema

// MARK: - SessionStore
//
// Per-session mirror registry + active pointer + cached session list. Owns
// the `[SessionId: ConversationMirror]` map and routes inbound `ui.*` /
// `conversation.*` notifications to the correct mirror.
//
// Per docs/designs/session-management.md "Shell 端字段三层":
//   - `ConversationMirror` (per-session) holds turns/status/lastError
//   - `SessionStore` (this class) does dictionary routing + active pointer
//   - global display state is derived from `mirrors[activeId]`
//
// Only `session.*` notifications are subscribed here. `ui.*` and
// `conversation.*` are forwarded by `AgentService` after parsing the
// `sessionId` field, since the routing dictionary is the natural seam — but
// the actual application happens via `mirror.applyXxx(...)`.

/// Surface for failures of session-management actions (create / activate /
/// list refresh). UI subscribes to this and shows a transient banner so
/// failed clicks don't look like silent successes.
public struct SessionActionError: Equatable, Sendable {
    public enum Kind: Sendable {
        case create
        case activate
        case list
    }
    public let kind: Kind
    public let message: String
    public let sessionId: String?
}

@MainActor
@Observable
public final class SessionStore {
    public private(set) var mirrors: [String: ConversationMirror] = [:]
    public private(set) var activeId: String?
    /// Sorted by sidecar's natural order (creation order). The history button
    /// re-sorts client-side if it wants newest-first.
    public private(set) var list: [SessionListItem] = []
    /// Last failed session-management action, surfaced to the UI. Nil once
    /// the user dismisses or the next action succeeds.
    public var lastActionError: SessionActionError?
    /// Set by `CompositionRoot` when bootstrap `session.create` fails.
    /// Distinct from `lastActionError` because it survives subsequent
    /// successful actions — until the boot sequence is retried (currently
    /// only by restart) the agent loop has no usable session and the
    /// composer must stay disabled with a precise message.
    public var bootError: String?

    private let rpc: RPCClient
    private let sessionService: SessionService

    public init(rpc: RPCClient, sessionService: SessionService) {
        self.rpc = rpc
        self.sessionService = sessionService
        registerHandlers()
    }

    // MARK: - Public API

    /// Mirror for a given sessionId, creating an empty one on first sight.
    /// `ui.*` / `conversation.*` may arrive for sessions Shell hasn't yet
    /// observed via `session.created` (a session created before Shell connect,
    /// or a notification race) — creating on demand keeps routing total.
    public func mirror(for sessionId: String) -> ConversationMirror {
        if let m = mirrors[sessionId] { return m }
        let m = ConversationMirror(sessionId: sessionId)
        mirrors[sessionId] = m
        return m
    }

    public var activeMirror: ConversationMirror? {
        guard let id = activeId else { return nil }
        return mirrors[id]
    }

    /// `+` should only mint a session when the current active conversation
    /// already contains user-visible work. An empty active mirror is already
    /// the blank conversation the user is asking for.
    public var canCreateNewConversation: Bool {
        guard let activeMirror else { return true }
        return !activeMirror.turns.isEmpty || activeMirror.lastErrorMessage?.isEmpty == false
    }

    /// Apply a `session.activate` response atomically: merge the snapshot
    /// into the target mirror and flip `activeId` in the same statement.
    /// Called by `SessionService.activate` once the response arrives.
    /// The trailing `session.activated` notification is audit-only.
    public func applyActivate(sessionId: String, snapshot: [ConversationTurnWire]) {
        mirror(for: sessionId).mergeActivateSnapshot(snapshot)
        activeId = sessionId
        lastActionError = nil
    }

    /// Apply a `session.create` response atomically: ensure the mirror,
    /// append to the cached list (keeping creation order), flip `activeId`.
    /// Called by `SessionService.create`. Both the bootstrap path and the
    /// "+" header button funnel through this — there is exactly one place
    /// where a freshly-created session enters the Shell's state.
    public func adoptCreated(_ session: SessionListItem) {
        if mirrors[session.id] == nil {
            mirrors[session.id] = ConversationMirror(sessionId: session.id)
        }
        if let idx = list.firstIndex(where: { $0.id == session.id }) {
            list[idx] = session
        } else {
            list.append(session)
        }
        activeId = session.id
        lastActionError = nil
    }

    /// Pull a fresh `session.list` from the sidecar. Called on app boot and
    /// on every `session.listChanged` notification — turnCount/lastActivityAt
    /// are sidecar-derived, so a refresh is the only correct way to keep the
    /// list in sync. Throws so callers can surface failures (history panel
    /// shows a banner; `handleListChanged` writes `lastActionError`).
    @discardableResult
    public func refreshList() async throws -> SessionListResult {
        do {
            let result = try await sessionService.list()
            applyListResult(result)
            return result
        } catch {
            FileHandle.standardError.write(
                Data("[shell] session.list refresh failed: \(error)\n".utf8)
            )
            throw error
        }
    }

    /// Project a fresh `SessionListResult` into the store. Factored out of
    /// `refreshList` so tests can drive the merge path without spinning up
    /// a real RPC round-trip.
    ///
    /// **Does NOT touch `activeId`.** Per the activate-contract single source:
    /// `activeId` is driven only by `session.create` / `session.activate`
    /// responses (`adoptCreated` / `applyActivate`). Letting list refresh
    /// also write it reintroduces the race we just removed — a `listChanged`
    /// arriving while an activate response is still pending could overwrite
    /// the optimistic flip with the sidecar's stale activeId.
    public func applyListResult(_ result: SessionListResult) {
        self.list = result.sessions
        for item in result.sessions where mirrors[item.id] == nil {
            mirrors[item.id] = ConversationMirror(sessionId: item.id)
        }
        // A successful refresh resolves the previous "couldn't reach
        // session.list" banner, so the property comment ("cleared when the
        // next action succeeds") holds for refresh just like for create /
        // activate.
        lastActionError = nil
    }

    /// Set / clear the action error from outside (e.g. UI dismissing a
    /// banner, or callers that wrap their own action in a do/catch).
    public func setActionError(_ error: SessionActionError?) {
        lastActionError = error
    }

    // MARK: - Notification subscriptions

    private func registerHandlers() {
        rpc.registerNotificationHandler(method: RPCMethod.sessionCreated) {
            [weak self] (params: SessionCreatedNotificationParams) in
            await self?.handleCreated(params)
        }
        rpc.registerNotificationHandler(method: RPCMethod.sessionActivated) {
            [weak self] (params: SessionActivatedNotificationParams) in
            await self?.handleActivated(params)
        }
        rpc.registerNotificationHandler(method: RPCMethod.sessionListChanged) {
            [weak self] (_: SessionListChangedNotificationParams) in
            await self?.handleListChanged()
        }
    }

    internal func handleCreated(_ p: SessionCreatedNotificationParams) {
        if mirrors[p.session.id] == nil {
            mirrors[p.session.id] = ConversationMirror(sessionId: p.session.id)
        }
        if let idx = list.firstIndex(where: { $0.id == p.session.id }) {
            list[idx] = p.session
        } else {
            list.append(p.session)
        }
    }

    /// Audit-only — `activeId` is driven by the `session.activate` /
    /// `session.create` responses (see `applyActivate` / `adoptCreated`).
    /// The sidecar dispatcher writes the `session.activated` notification
    /// before the matching response, so writing `activeId` here would
    /// expose an empty mirror to SwiftUI for one frame before the snapshot
    /// merges. We still ensure the mirror exists so subsequent `ui.*`
    /// notifications routed under this id always have a target.
    internal func handleActivated(_ p: SessionActivatedNotificationParams) {
        if mirrors[p.sessionId] == nil {
            mirrors[p.sessionId] = ConversationMirror(sessionId: p.sessionId)
        }
    }

    internal func handleListChanged() async {
        do {
            _ = try await refreshList()
        } catch {
            lastActionError = SessionActionError(
                kind: .list,
                message: "Failed to refresh session list: \(error.localizedDescription)",
                sessionId: nil
            )
        }
    }
}
