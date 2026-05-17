import Foundation
import RPCSchema

// MARK: - DevContextService
//
// Shell-side mirror of the Sidecar's `ContextObserver`. Observes
// `dev.context.changed` notifications and (on demand) issues `dev.context.get`
// to hydrate the latest snapshot — this matters when the Dev Mode window is
// opened *between* turns and would otherwise stay empty until the next
// `agent.submit`.
//
// Architecture boundary: the service knows the wire schema, nothing more. It
// does not touch the agent loop, the conversation mirror, or the notch UI;
// the only coupling is the read-only RPCClient passed in. This keeps Dev
// Mode purely observational — disabling or removing it cannot affect the
// agent path.

@MainActor
@Observable
public final class DevContextService {
    public private(set) var snapshot: DevContextSnapshot?

    /// Most recent `refresh()` failure. Nil when the last refresh succeeded
    /// or `refresh()` has never run. The Dev Mode panel renders this
    /// explicitly — silently swallowing errors in a diagnostic surface
    /// defeats the purpose (per AGENTS.md "Fail fast and loudly").
    public private(set) var lastError: String?

    private let rpc: RPCClient

    public init(rpc: RPCClient) {
        self.rpc = rpc
        registerHandlers()
    }

    private func registerHandlers() {
        rpc.registerNotificationHandler(method: RPCMethod.devContextChanged) {
            [weak self] (params: DevContextChangedParams) in
            await self?.apply(params.snapshot)
        }
    }

    /// Pull the latest snapshot from the sidecar. Called when the Dev Mode
    /// window opens; the notification stream then keeps it live thereafter.
    /// Failures are recorded into `lastError` (visible in the panel) instead
    /// of being thrown — `.task` callers have no error boundary.
    public func refresh() async {
        do {
            let result: DevContextGetResult = try await rpc.request(
                method: RPCMethod.devContextGet,
                params: DevContextGetParams(),
                as: DevContextGetResult.self
            )
            if let snap = result.snapshot {
                snapshot = snap
            }
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    private func apply(_ snap: DevContextSnapshot) {
        snapshot = snap
        // A successful inbound notification implies the wire is healthy;
        // clear any prior refresh error so the panel doesn't mislead with
        // a stale failure banner once data is flowing again.
        lastError = nil
    }
}
