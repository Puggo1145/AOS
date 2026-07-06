import Foundation

// MARK: - Session management intents
//
// Orchestration for the header strip's "new conversation" / "history"
// buttons and the history panel's row-activate action. Per
// docs/designs/notch-ui.md, views forward intents only — the guard +
// RPC call + error-wrapping sequencing that used to live in button
// closures belongs here.

extension NotchViewModel {
    /// `+` should only mint a session when there's user-visible work to
    /// leave behind — mirrors `SessionStore.canCreateNewConversation`.
    /// Exposed here so `NotchHeaderStripsView` doesn't reach through
    /// `agentService.sessionStore` just to bind `.disabled(...)`.
    public var canCreateNewConversation: Bool {
        agentService.sessionStore.canCreateNewConversation
    }

    /// Start a fresh conversation from the header "+" button.
    /// `SessionService.create` auto-activates via `SessionStore.adoptCreated`
    /// so the mirror + activeId flip atomically before SwiftUI reads them.
    func startNewConversation() async {
        guard canCreateNewConversation else { return }
        do {
            _ = try await sessionService.create()
        } catch {
            agentService.sessionStore.setActionError(
                SessionActionError(
                    kind: .create,
                    message: "Failed to start a new conversation: \(error.localizedDescription)",
                    sessionId: nil
                )
            )
        }
    }

    /// Refresh the session list, then open the history panel regardless of
    /// refresh outcome — the panel renders the cached list and surfaces a
    /// banner if the refresh failed.
    func openHistory() async {
        let store = agentService.sessionStore
        do {
            _ = try await store.refreshList()
        } catch {
            store.setActionError(SessionActionError(
                kind: .list,
                message: "Failed to refresh sessions: \(error.localizedDescription)",
                sessionId: nil
            ))
        }
        showHistory = true
    }

    /// Switch the active session from a history-panel row tap. Returns
    /// `true` on success so the caller (the history panel) knows whether
    /// to close itself — kept open on failure so the error banner has
    /// somewhere to render instead of vanishing with the panel.
    @discardableResult
    func activateSession(id: String, title: String) async -> Bool {
        do {
            _ = try await sessionService.activate(sessionId: id)
            return true
        } catch {
            agentService.sessionStore.setActionError(SessionActionError(
                kind: .activate,
                message: "Failed to switch to “\(title)”: \(error.localizedDescription)",
                sessionId: id
            ))
            return false
        }
    }

    /// Dismiss the session action-error banner (create / activate / list
    /// refresh failure), wherever it's shown.
    func dismissSessionActionError() {
        agentService.sessionStore.setActionError(nil)
    }
}
