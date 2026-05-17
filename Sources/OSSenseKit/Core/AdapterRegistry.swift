import Foundation

// MARK: - AdapterRegistry
//
// Per `docs/designs/os-sense.md` §"加新 adapter 的成本": the registry is the
// composition seam where Shell injects concrete adapters. Stage 0 ships an
// empty registry — design explicitly permits the zero-adapter state, and
// the Stage 0 scope row in the plan forbids registering any adapter here.
//
// `route(toApp:)`-style logic will land alongside Stage 2 (when the first
// concrete adapters arrive). Today only the registration + lookup primitive
// is needed.

public actor AdapterRegistry {
    private var adapters: [any SenseAdapter] = []

    public init() {}

    /// Register an adapter instance. Order is preserved; per design, when a
    /// single bundle id is matched by multiple adapters, attach order follows
    /// registration order.
    public func register(_ adapter: any SenseAdapter) {
        adapters.append(adapter)
    }

    /// Return adapters whose `supportedBundleIds` contain `bundleId`.
    public func adapters(matching bundleId: String) -> [any SenseAdapter] {
        adapters.filter { type(of: $0).supportedBundleIds.contains(bundleId) }
    }

    /// Snapshot of all registered adapters (test-only convenience).
    public func allAdapters() -> [any SenseAdapter] {
        adapters
    }
}
