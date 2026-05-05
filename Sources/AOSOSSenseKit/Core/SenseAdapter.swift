import Foundation

// MARK: - SenseAdapter protocol
//
// Per `docs/designs/os-sense.md` §"SenseAdapter 协议".
//
// `attach` is the seam where adapters subscribe to AX (or other) signals
// for `target`. Adapters MUST go through the shared `AXObserverHub` for
// any AX subscription so observer lifetimes are managed in one place
// (design §"共享 AX 底座"). Each yield from the returned stream is the
// adapter's **complete** current envelope set — `SenseStore` replaces
// the slot wholesale, never appends.
//
// `hub` is `@MainActor`-isolated; an actor adapter calling into it must
// `await`. That's the design intent: the hub serializes AX observer
// mutations behind one isolation boundary.
//
// ## attach() contract — non-negotiable
//
// `attach` is on the swap chain's critical path. A misbehaving adapter
// can stall every subsequent app switch and permission flip, because
// SenseStore serializes swaps through `pendingSwap` to keep detach/attach
// from interleaving. To keep that serialization safe, `attach` is bound
// by the following hard rules:
//
//   1. **Fast.** Return within tens of milliseconds. The store enforces a
//      500ms diagnostic timeout (logged + counted via
//      `_attachTimeoutCount`); going past it is treated as an adapter
//      bug, not a runtime condition.
//   2. **No synchronous AX / Apple Event reads.** AX attribute copies and
//      Apple Event sends can block on the target process's responsiveness
//      and don't honor Swift task cancellation. `attach` may only call
//      `hub.subscribe(...)` and prepare its `AsyncStream`. Any attribute
//      read MUST happen inside the per-notification handler (already on
//      the main runloop, already debounced by the adapter).
//   3. **No work before the stream is returned.** If an adapter needs an
//      initial read, it must schedule the same debounced handler used by
//      later notifications after `attach` has prepared the stream. Latency
//      inside attach is pure swap-chain cost.
//   4. **Cancellation-aware.** The async work `attach` does (the few
//      `await hub.subscribe(...)` hops) MUST honor `Task.isCancelled`. If
//      the swap chain cancels mid-attach, return promptly without
//      yielding into the stream.
//
// Violating any of the above does not just produce a slow chip — it
// blocks the swap chain. Treat `attach` like a signal-handler: register
// subscriptions, return the stream, get out.

public typealias AdapterID = String

/// A frontmost-app target handed to an adapter at attach time.
public struct RunningApp: Sendable, Equatable {
    public let bundleId: String
    public let pid: pid_t

    public init(bundleId: String, pid: pid_t) {
        self.bundleId = bundleId
        self.pid = pid
    }
}

public protocol SenseAdapter: Actor {
    static var id: AdapterID { get }
    static var supportedBundleIds: Set<String> { get }
    /// Permissions whose denial MUST block this adapter's `attach` and
    /// trigger detach when revoked at runtime. The store gates on this
    /// set in `attachAdaptersForCurrentApp` and re-runs the swap whenever
    /// `PermissionState.denied` changes.
    ///
    /// **AX consumer rule (non-negotiable):** any adapter that subscribes
    /// through `AXObserverHub` (i.e. consumes any `kAX*` notification)
    /// MUST include `.accessibility` here. The hub is a router, not a
    /// permission gate — `AXObserverCreate` silently fails when
    /// Accessibility is denied, so an empty `requiredPermissions` would
    /// let an AX adapter "attach" into a no-op state and falsely occupy
    /// a chip slot. Declaring `.accessibility` is what keeps the
    /// detach-on-revoke path correct: when the user disables
    /// Accessibility, the swap chain pulls the adapter back down instead
    /// of leaving a husk attached.
    ///
    /// Permissions required by the live stream itself belong here. If an
    /// adapter performs Apple Events as part of its live notification
    /// handler, it must include `.automation`; if Apple Events are only used
    /// for a separate user-triggered enrichment action, that action owns its
    /// permission flow instead.
    var requiredPermissions: Set<Permission> { get }

    /// Subscribe to AX (or other) signals for `target` via the shared `hub`
    /// and return an `AsyncStream` of full envelope sets. Each emission
    /// **replaces** the previous set in `SenseStore`'s `behaviorsBySource`.
    ///
    /// Implementations MUST honor the contract documented at the top of
    /// this file: fast, no synchronous AX / Apple Event reads, no
    /// enrichment prefetch, cancellation-aware. Violations stall the
    /// swap chain — they are bugs, not runtime conditions.
    func attach(hub: AXObserverHub, target: RunningApp) async -> AsyncStream<[BehaviorEnvelope]>

    /// Called when `target` leaves the foreground; adapter must release all
    /// subscriptions / observers it holds via the hub.
    func detach() async

    /// Re-read the adapter's current lightweight context on demand. Called
    /// when the user opens OS Sense so app-specific adapters get the same
    /// fresh snapshot chance as `GeneralProbe`, without requiring an app
    /// switch or a new AX notification.
    func refresh() async
}

public extension SenseAdapter {
    func refresh() async {}
}
