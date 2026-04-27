import Testing
import Foundation
import CoreGraphics
@testable import AOSOSSenseKit

// MARK: - Mock adapters
//
// Hand-driven SenseAdapter conformances that bypass AX entirely so the
// SenseStore plumbing (attach / detach / consume / timeout / permission
// gating) can be exercised without real AX permissions.

private actor MockAdapter: SenseAdapter {
    static let id: AdapterID = "mock"
    static var supportedBundleIds: Set<String> = ["com.test.app"]
    nonisolated let requiredPermissions: Set<Permission> = []

    private var continuation: AsyncStream<[BehaviorEnvelope]>.Continuation?
    private(set) var attachCount = 0
    private(set) var detachCount = 0

    func attach(hub: AXObserverHub, target: RunningApp) async -> AsyncStream<[BehaviorEnvelope]> {
        attachCount += 1
        var captured: AsyncStream<[BehaviorEnvelope]>.Continuation!
        let stream = AsyncStream<[BehaviorEnvelope]> { c in
            captured = c
        }
        self.continuation = captured
        return stream
    }

    func detach() async {
        detachCount += 1
        continuation?.finish()
        continuation = nil
    }

    func emit(_ envelopes: [BehaviorEnvelope]) {
        continuation?.yield(envelopes)
    }
}

private actor SlowAttachAdapter: SenseAdapter {
    static let id: AdapterID = "slow"
    static var supportedBundleIds: Set<String> = ["com.test.slow"]
    nonisolated let requiredPermissions: Set<Permission> = []

    func attach(hub: AXObserverHub, target: RunningApp) async -> AsyncStream<[BehaviorEnvelope]> {
        // Sleep past the 500ms attach timeout so the store should give up
        // on us. When the surrounding TaskGroup cancels, the sleep throws
        // CancellationError → swallowed, then we still return a stream
        // that nobody is listening to.
        try? await Task.sleep(nanoseconds: 700_000_000)
        return AsyncStream { _ in }
    }

    func detach() async {}
}

private actor PermissionedAdapter: SenseAdapter {
    static let id: AdapterID = "permissioned"
    static var supportedBundleIds: Set<String> = ["com.test.app"]
    nonisolated let requiredPermissions: Set<Permission> = [.automation]

    private(set) var attachCount = 0
    private(set) var detachCount = 0

    func attach(hub: AXObserverHub, target: RunningApp) async -> AsyncStream<[BehaviorEnvelope]> {
        attachCount += 1
        return AsyncStream { _ in }
    }

    func detach() async {
        detachCount += 1
    }
}

/// Stable-ID adapter parameterised over its own AdapterID + supported
/// bundle so tests can stand up multiple distinct adapters covering the
/// same bundle without copy-pasting types. Each subclass-style instance
/// pins a single `id` / `supportedBundleIds` pair via the static config
/// it's initialised against, but Swift's static protocol requirements
/// force one type per ID — so we use three concrete tiny adapters below
/// for the registration-order test.
private actor OrderAdapterA: SenseAdapter {
    static let id: AdapterID = "order.a"
    static var supportedBundleIds: Set<String> = ["com.test.order"]
    nonisolated let requiredPermissions: Set<Permission> = []
    func attach(hub: AXObserverHub, target: RunningApp) async -> AsyncStream<[BehaviorEnvelope]> {
        AsyncStream { c in c.yield([.init(kind: "k", citationKey: "a:1", displaySummary: "A", payload: .object([:]))]); c.finish() }
    }
    func detach() async {}
}

private actor OrderAdapterB: SenseAdapter {
    static let id: AdapterID = "order.b"
    static var supportedBundleIds: Set<String> = ["com.test.order"]
    nonisolated let requiredPermissions: Set<Permission> = []
    func attach(hub: AXObserverHub, target: RunningApp) async -> AsyncStream<[BehaviorEnvelope]> {
        AsyncStream { c in c.yield([.init(kind: "k", citationKey: "b:1", displaySummary: "B", payload: .object([:]))]); c.finish() }
    }
    func detach() async {}
}

/// AX consumer fixture: declares `.accessibility` per the protocol's
/// "AX consumer rule". Used to lock down the contract that an AX-touching
/// adapter detaches when Accessibility is revoked, instead of attaching
/// into a husk state where `AXObserverCreate` silently fails.
private actor AccessibilityAdapter: SenseAdapter {
    static let id: AdapterID = "ax"
    static var supportedBundleIds: Set<String> = ["com.test.ax"]
    nonisolated let requiredPermissions: Set<Permission> = [.accessibility]

    private(set) var attachCount = 0
    private(set) var detachCount = 0

    func attach(hub: AXObserverHub, target: RunningApp) async -> AsyncStream<[BehaviorEnvelope]> {
        attachCount += 1
        return AsyncStream { _ in }
    }

    func detach() async {
        detachCount += 1
    }
}

private actor OrderAdapterC: SenseAdapter {
    static let id: AdapterID = "order.c"
    static var supportedBundleIds: Set<String> = ["com.test.order"]
    nonisolated let requiredPermissions: Set<Permission> = []
    func attach(hub: AXObserverHub, target: RunningApp) async -> AsyncStream<[BehaviorEnvelope]> {
        AsyncStream { c in c.yield([.init(kind: "k", citationKey: "c:1", displaySummary: "C", payload: .object([:]))]); c.finish() }
    }
    func detach() async {}
}

@MainActor
@Suite("SenseStore — adapter plumbing")
struct SenseStoreAdapterPlumbingTests {

    private func envelope(_ key: String, _ summary: String) -> BehaviorEnvelope {
        BehaviorEnvelope(
            kind: "mock.signal",
            citationKey: key,
            displaySummary: summary,
            payload: .object([:])
        )
    }

    private func makeStore(adapters: [any SenseAdapter] = []) async -> SenseStore {
        let registry = AdapterRegistry()
        for adapter in adapters { await registry.register(adapter) }
        return SenseStore(
            permissionsService: PermissionsService(),
            registry: registry
        )
    }

    @Test("Matching adapter attaches on app activation and emits flow into context")
    func attachAndEmit() async {
        let mock = MockAdapter()
        let store = await makeStore(adapters: [mock])

        store._applyFrontmostForTesting(
            app: AppIdentity(bundleId: "com.test.app", name: "Test", pid: 100, icon: nil),
            window: WindowIdentity(title: "Test", windowId: nil)
        )
        await store._awaitPendingAdapterSwapForTesting()

        #expect(store._attachedAdapterIdsForTesting.contains("mock"))
        let attaches = await mock.attachCount
        #expect(attaches == 1)

        // Drive an emission and confirm it surfaces in context.behaviors.
        await mock.emit([envelope("m:1", "first")])
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.context.behaviors.contains { $0.citationKey == "m:1" })
    }

    @Test("App switch detaches the previous adapter and clears its envelopes")
    func detachOnSwitch() async {
        let mock = MockAdapter()
        let store = await makeStore(adapters: [mock])

        store._applyFrontmostForTesting(
            app: AppIdentity(bundleId: "com.test.app", name: "Test", pid: 100, icon: nil),
            window: WindowIdentity(title: "Test", windowId: nil)
        )
        await store._awaitPendingAdapterSwapForTesting()
        await mock.emit([envelope("m:1", "first")])
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.context.behaviors.contains { $0.citationKey == "m:1" })

        // Switch to an app whose bundleId nobody covers.
        store._applyFrontmostForTesting(
            app: AppIdentity(bundleId: "com.other.app", name: "Other", pid: 200, icon: nil),
            window: WindowIdentity(title: "Other", windowId: nil)
        )
        await store._awaitPendingAdapterSwapForTesting()

        let detaches = await mock.detachCount
        #expect(detaches == 1)
        #expect(store._attachedAdapterIdsForTesting.isEmpty)
        #expect(store.context.behaviors.isEmpty)
    }

    @Test("Slow attach (>500ms) is treated as a failed adapter — no contribution")
    func slowAttachTimesOut() async {
        let slow = SlowAttachAdapter()
        let store = await makeStore(adapters: [slow])

        store._applyFrontmostForTesting(
            app: AppIdentity(bundleId: "com.test.slow", name: "Slow", pid: 300, icon: nil),
            window: WindowIdentity(title: "Slow", windowId: nil)
        )
        await store._awaitPendingAdapterSwapForTesting()

        // Adapter timed out — never registered as attached, no envelopes
        // contributed. (Failure isolation: other producers, if any, would
        // still work — there are none in this test.)
        #expect(!store._attachedAdapterIdsForTesting.contains("slow"))
        #expect(store.context.behaviors.isEmpty)
    }

    @Test("Adapter requiring a denied permission is skipped at attach")
    func permissionGatedSkip() async {
        let permissioned = PermissionedAdapter()
        let store = await makeStore(adapters: [permissioned])

        store._applyPermissionsForTesting(PermissionState(denied: [.automation]))
        store._applyFrontmostForTesting(
            app: AppIdentity(bundleId: "com.test.app", name: "Test", pid: 400, icon: nil),
            window: WindowIdentity(title: "Test", windowId: nil)
        )
        await store._awaitPendingAdapterSwapForTesting()

        let attaches = await permissioned.attachCount
        #expect(attaches == 0)
        #expect(!store._attachedAdapterIdsForTesting.contains("permissioned"))
    }

    // Regression for #2: when a previously-denied permission flips to
    // granted, the store re-runs the swap and the adapter attaches without
    // an app switch. Without this re-swap, an adapter that declares a
    // required permission would never come online if the user grants the
    // permission *after* startup.
    @Test("Permission grant after attach skip triggers re-attach")
    func permissionGrantTriggersAttach() async {
        let permissioned = PermissionedAdapter()
        let store = await makeStore(adapters: [permissioned])

        // Start denied → adapter is skipped at attach time.
        store._applyPermissionsForTesting(PermissionState(denied: [.automation]))
        store._applyFrontmostForTesting(
            app: AppIdentity(bundleId: "com.test.app", name: "Test", pid: 401, icon: nil),
            window: WindowIdentity(title: "Test", windowId: nil)
        )
        await store._awaitPendingAdapterSwapForTesting()
        #expect(!store._attachedAdapterIdsForTesting.contains("permissioned"))

        // Grant the permission → store should re-run swap and attach.
        store._applyPermissionsForTesting(PermissionState(denied: []))
        await store._awaitPendingAdapterSwapForTesting()

        let attaches = await permissioned.attachCount
        #expect(attaches == 1)
        #expect(store._attachedAdapterIdsForTesting.contains("permissioned"))
    }

    // Inverse: granted-then-revoked must detach. Without the re-swap on
    // permission flip, a revoked permission would leave a now-illegal
    // adapter still attached.
    @Test("Permission revoke after attach triggers detach")
    func permissionRevokeTriggersDetach() async {
        let permissioned = PermissionedAdapter()
        let store = await makeStore(adapters: [permissioned])

        store._applyPermissionsForTesting(PermissionState(denied: []))
        store._applyFrontmostForTesting(
            app: AppIdentity(bundleId: "com.test.app", name: "Test", pid: 402, icon: nil),
            window: WindowIdentity(title: "Test", windowId: nil)
        )
        await store._awaitPendingAdapterSwapForTesting()
        #expect(store._attachedAdapterIdsForTesting.contains("permissioned"))

        store._applyPermissionsForTesting(PermissionState(denied: [.automation]))
        await store._awaitPendingAdapterSwapForTesting()

        let detaches = await permissioned.detachCount
        #expect(detaches >= 1)
        #expect(!store._attachedAdapterIdsForTesting.contains("permissioned"))
    }

    // Regression for #3: chip-row order must equal registration order
    // across the merged behaviors view. Three adapters covering the same
    // bundle, registered A → B → C; behaviors must surface in that order.
    @Test("Multiple adapters surface behaviors in registration order")
    func adapterRegistrationOrderPreserved() async {
        let store = await makeStore(adapters: [OrderAdapterA(), OrderAdapterB(), OrderAdapterC()])

        store._applyFrontmostForTesting(
            app: AppIdentity(bundleId: "com.test.order", name: "Order", pid: 500, icon: nil),
            window: WindowIdentity(title: "Order", windowId: nil)
        )
        await store._awaitPendingAdapterSwapForTesting()
        // Streams emit synchronously inside the AsyncStream init closure,
        // but the consumer Task only schedules the apply once it gets to
        // run. A short yield lets each adapter's first emission flush.
        for _ in 0..<10 {
            await Task.yield()
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(store._attachedAdapterOrderForTesting == ["order.a", "order.b", "order.c"])
        let keys = store.context.behaviors.map { $0.citationKey }
        #expect(keys == ["a:1", "b:1", "c:1"])
    }

    // Closes the AX-consumer contract: an adapter that consumes AX
    // notifications via the hub MUST declare `.accessibility` in
    // `requiredPermissions`. With that contract, Accessibility revoke
    // detaches the adapter; without it, the swap pipeline would re-attach
    // a husk that AXObserverCreate silently failed to wire up. This test
    // exercises both directions (denied→granted→denied) on a fixture
    // adapter that follows the contract.
    @Test("Accessibility revoke detaches an AX adapter that declared .accessibility")
    func accessibilityRevokeDetachesAXAdapter() async {
        let ax = AccessibilityAdapter()
        let store = await makeStore(adapters: [ax])

        // Denied at startup → not attached.
        store._applyPermissionsForTesting(PermissionState(denied: [.accessibility]))
        store._applyFrontmostForTesting(
            app: AppIdentity(bundleId: "com.test.ax", name: "AX", pid: 700, icon: nil),
            window: WindowIdentity(title: "AX", windowId: nil)
        )
        await store._awaitPendingAdapterSwapForTesting()
        #expect(!store._attachedAdapterIdsForTesting.contains("ax"))

        // Grant Accessibility → swap re-runs → adapter attaches.
        store._applyPermissionsForTesting(PermissionState(denied: []))
        await store._awaitPendingAdapterSwapForTesting()
        let attachesAfterGrant = await ax.attachCount
        #expect(attachesAfterGrant == 1)
        #expect(store._attachedAdapterIdsForTesting.contains("ax"))

        // Revoke Accessibility → swap re-runs → adapter detaches. This is
        // the case Codex flagged: without the AX-consumer contract, a
        // `requiredPermissions = []` adapter would reattach here as a
        // husk. With the contract, the gate fires and the slot is freed.
        store._applyPermissionsForTesting(PermissionState(denied: [.accessibility]))
        await store._awaitPendingAdapterSwapForTesting()
        let detachesAfterRevoke = await ax.detachCount
        #expect(detachesAfterRevoke >= 1)
        #expect(!store._attachedAdapterIdsForTesting.contains("ax"))
    }

    // Regression for #4 observability: a slow attach must bump the
    // diagnostic counter so a future misbehaving adapter is noticed
    // instead of silently swallowing into nil.
    @Test("Slow attach increments the diagnostic timeout counter")
    func slowAttachBumpsTimeoutCounter() async {
        let slow = SlowAttachAdapter()
        let store = await makeStore(adapters: [slow])

        #expect(store._attachTimeoutCountForTesting == 0)
        store._applyFrontmostForTesting(
            app: AppIdentity(bundleId: "com.test.slow", name: "Slow", pid: 600, icon: nil),
            window: WindowIdentity(title: "Slow", windowId: nil)
        )
        await store._awaitPendingAdapterSwapForTesting()

        #expect(store._attachTimeoutCountForTesting == 1)
    }
}
