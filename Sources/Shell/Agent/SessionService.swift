import Foundation
import RPCSchema

// MARK: - SessionService
//
// Wraps the three Shell→Bun `session.*` requests. `SessionStore` is the single
// source of truth for active id and per-session mirrors; this layer only:
//
//   1. issues the RPC,
//   2. on success, hands the response to the store via the atomic adopt /
//      activate hooks so mirror+activeId flip in the same MainActor frame.
//
// The sidecar also broadcasts `session.created` / `session.activated` /
// `session.listChanged` notifications, but those are demoted to *audit* —
// `SessionStore.handleActivated` no longer writes `activeId`. The contract
// is: the response is truth; the notification is a trailing announcement
// (see docs/designs/rpc-protocol.md).
//
// Why response-driven instead of notification-driven: the sidecar dispatcher
// emits `session.activated` synchronously inside `manager.activate(...)`,
// then writes the response after the handler returns. Shell receives the
// notification first; if Shell flipped activeId on the notification, SwiftUI
// could observe an empty mirror for one frame before the response merges
// the snapshot. Driving the flip from the response eliminates that window.

@MainActor
public final class SessionService {
    private let rpc: RPCClient
    /// Wired by `CompositionRoot` after both services exist; required for
    /// `create` / `activate` to project results into the store. Tests that
    /// only exercise the wire surface can leave it unset.
    public weak var sessionStore: SessionStore?

    public init(rpc: RPCClient) {
        self.rpc = rpc
    }

    /// Create a new session and adopt it as the current one. The sidecar
    /// auto-activates on `session.create`; the store's `adoptCreated`
    /// atomically inserts the mirror, appends to the cached list, and sets
    /// `activeId` so SwiftUI re-renders against an empty-but-active mirror
    /// in one frame. Returns the SessionListItem the sidecar minted.
    @discardableResult
    public func create(title: String? = nil) async throws -> SessionListItem {
        let result = try await rpc.request(
            method: RPCMethod.sessionCreate,
            params: SessionCreateParams(title: title),
            as: SessionCreateResult.self
        )
        sessionStore?.adoptCreated(result.session)
        return result.session
    }

    public func list() async throws -> SessionListResult {
        try await rpc.request(
            method: RPCMethod.sessionList,
            params: SessionListParams(),
            as: SessionListResult.self
        )
    }

    /// Switch the sidecar's active session. The store's `applyActivate`
    /// merges the returned snapshot into the target mirror and flips
    /// `activeId` in the same statement, so SwiftUI never observes a
    /// half-populated active mirror.
    @discardableResult
    public func activate(sessionId: String) async throws -> SessionActivateResult {
        let result = try await rpc.request(
            method: RPCMethod.sessionActivate,
            params: SessionActivateParams(sessionId: sessionId),
            as: SessionActivateResult.self
        )
        sessionStore?.applyActivate(sessionId: sessionId, snapshot: result.snapshot)
        return result
    }
}
