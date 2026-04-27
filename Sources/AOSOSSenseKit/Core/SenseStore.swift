import Foundation
import AppKit
import os

// MARK: - SenseStore
//
// Per `docs/designs/os-sense.md` §"核心范式：live state mirror" and §"架构总览".
// Single owner of `SenseContext`; all writes funneled through @MainActor
// helpers. Producers (WindowMirror, GeneralProbe, registered adapters) push
// field-scoped updates; this class composes them into the canonical context.
//
// Clipboard is intentionally NOT a live producer: per design §"Clipboard
// capture" the pasteboard is sampled by the Shell composer at user-paste
// time. SenseStore therefore has no `clipboard` field and no polling loop.
//
// Multi-source `behaviors` slot (§"事件源与字段映射"): GeneralProbe + each
// adapter contributes a complete envelope set keyed by source id; the store
// merges them at every write so removing a source is just "forget that key".
// Order: general first, then adapters in registration order — keeps the
// chip row visually stable across app switches.
//
// Adapter plumbing (§"SenseAdapter 协议", §"加新 adapter 的成本"): on every
// frontmost change, the store queries `AdapterRegistry` for adapters whose
// `supportedBundleIds` cover the new app, attaches each (with a 500ms
// timeout + failure isolation per the design) and consumes the
// `AsyncStream<[BehaviorEnvelope]>` they return into `applyBehaviors`. App
// switches detach previous adapters before attaching new ones; concurrent
// swaps are serialized so cancellations don't tear adapter state.
//
// Visual fallback is **on demand**, not a live field. Submit-time capture
// only — see `captureVisualSnapshot()`. Continuous SCStream was rejected
// because it's the heaviest piece of background work in the read-side
// pipeline and the visual is only consumed at submit. The design doc was
// updated to match.
//
// Permission live-tracking: SwiftUI's `@Observable` change-tracking is used
// to react to PermissionsService updates without polling — when accessibility
// flips on, the probe + WindowMirror's AX side attach to the current app
// without restart, matching design §"权限".

@MainActor
@Observable
public final class SenseStore {
    public private(set) var context: SenseContext = .empty

    private let permissionsService: PermissionsService
    private let registry: AdapterRegistry
    private let hub: AXObserverHub
    private let screenMirror: ScreenMirror

    private var windowMirror: WindowMirror?
    private var generalProbe: GeneralProbe?

    /// Behaviors contributed per producer. Key "general" is GeneralProbe;
    /// adapters use their `AdapterID`. Empty arrays remove the entry so the
    /// merged list collapses cleanly when a producer goes quiet.
    private var behaviorsBySource: [String: [BehaviorEnvelope]] = [:]

    /// Adapters currently attached to the frontmost app, keyed by AdapterID.
    private var attachedAdapters: [AdapterID: any SenseAdapter] = [:]
    /// Attach order for the currently-attached adapters. Drives merge
    /// order in `mergeBehaviors` so the chip row stays stable across app
    /// switches. Pinned to `AdapterRegistry`'s registration order via
    /// `adapters(matching:)`. (Design §"事件源与字段映射": "general first,
    /// then adapters in registration order".)
    private var attachedAdapterOrder: [AdapterID] = []
    /// Consumer tasks for each attached adapter's AsyncStream. Cancel +
    /// await on detach.
    private var adapterTasks: [AdapterID: Task<Void, Never>] = [:]
    /// Single in-flight adapter swap task. New swaps await the previous one
    /// before running so detach/attach pairs never interleave.
    private var pendingSwap: Task<Void, Never>?

    /// Diagnostic counter: incremented each time `attach()` failed to
    /// return within the 500ms contract window. The timeout is informational
    /// — Swift cancellation is cooperative and we don't try to forcibly
    /// kill the underlying task. See `withAttachTimeout` for the rationale.
    private(set) var attachTimeoutCount: Int = 0

    private static let log = Logger(subsystem: "com.aos.AOSOSSenseKit", category: "SenseStore")

    public init(permissionsService: PermissionsService, registry: AdapterRegistry) {
        self.permissionsService = permissionsService
        self.registry = registry
        self.hub = AXObserverHub()
        self.screenMirror = ScreenMirror()
    }

    public func start() async {
        await permissionsService.refresh()
        applyPermissions(permissionsService.state)

        // Producers are constructed once; their lifecycles are driven by
        // app/permission changes, not by start/stop pairs.
        let probe = GeneralProbe(hub: hub) { [weak self] envelopes in
            self?.applyBehaviors(source: "general", envelopes: envelopes)
        }
        self.generalProbe = probe

        let windowMirror = WindowMirror(hub: hub) { [weak self] app, window in
            self?.applyFrontmost(app: app, window: window)
        }
        windowMirror.setAccessibilityGranted(
            !permissionsService.state.denied.contains(.accessibility)
        )
        self.windowMirror = windowMirror
        windowMirror.start()

        observePermissions()
    }

    public func stop() {
        windowMirror?.stop()
        windowMirror = nil
        generalProbe?.detach()
        generalProbe = nil
        if let pid = context.app?.pid {
            hub.detach(pid: pid)
        }
        behaviorsBySource.removeAll()
        // Tear down adapters. We can't synchronously await detach() of
        // each adapter from a non-async stop(), so schedule it on the
        // pending-swap chain — the chain's "previous swap finishes first"
        // ordering still holds.
        scheduleAdapterDetachAll()
    }

    // MARK: - Visual snapshot (on demand)
    //
    // Called at submit time by the Shell when the visual chip is selected.
    // Single async capture — no background loop. Returns nil if no frontmost
    // app, screen recording is denied, or capture itself fails.

    /// Whether a visual snapshot would succeed if requested right now —
    /// frontmost app exists AND screen recording is granted. Drives the UI
    /// chip's visibility so we don't show "Window snapshot" when it'd be
    /// guaranteed to come back nil.
    public var visualSnapshotAvailable: Bool {
        context.app != nil
            && !context.permissions.denied.contains(.screenRecording)
    }

    /// Re-read the prior frontmost app's focused element on demand. Called
    /// by the Shell when the Notch opens so the user sees their just-made
    /// selection immediately, without waiting for the source app to fire a
    /// `kAXSelectedTextChangedNotification` — terminals (Ghostty), Electron,
    /// and other custom-rendered apps either don't emit it or only emit it
    /// after subsequent focus shifts. The probe stays attached to the prior
    /// real app via `WindowMirror`'s self-activation suppression, so we just
    /// need to tell it to look again.
    public func refreshGeneralProbe() {
        generalProbe?.refresh()
    }

    /// Capture a single fresh window screenshot for the current frontmost app.
    /// Bypasses the AX behaviors gate — the caller decides whether to use it
    /// (typically: only when `behaviors` is empty, but we don't enforce that
    /// here).
    public func captureVisualSnapshot() async -> VisualMirror? {
        guard let pid = context.app?.pid else { return nil }
        guard !context.permissions.denied.contains(.screenRecording) else { return nil }
        return await screenMirror.captureNow(forPid: pid)
    }

    // MARK: - Field writers (single-writer invariant)

    private func applyFrontmost(app: AppIdentity?, window: WindowIdentity?) {
        let oldPid = context.app?.pid
        let newPid = app?.pid

        context = SenseContext(
            app: app,
            window: window,
            behaviors: context.behaviors,
            permissions: context.permissions
        )

        // App changed: tear down all per-pid AX state and any adapter envelopes
        // that were associated with the old app.
        if oldPid != newPid {
            generalProbe?.detach()
            if let oldPid {
                hub.detach(pid: oldPid)
            }
            if !behaviorsBySource.isEmpty {
                behaviorsBySource.removeAll()
                applyBehaviorsRecompute()
            }
            // Swap adapters for the new bundle id. Sequenced through
            // pendingSwap so detach/attach never overlap.
            scheduleAdapterSwap()
        }

        // Attach probe to the new app iff Accessibility is granted.
        if let newPid,
           !context.permissions.denied.contains(.accessibility) {
            generalProbe?.attach(pid: newPid)
        }
    }

    private func applyBehaviors(source: String, envelopes: [BehaviorEnvelope]) {
        if envelopes.isEmpty {
            behaviorsBySource.removeValue(forKey: source)
        } else {
            behaviorsBySource[source] = envelopes
            // Pin the source's merge slot on first non-empty write so the
            // chip row order is stable. Idempotent for adapters that
            // `attachAdaptersForCurrentApp` already pre-registered in
            // registration order; for direct producers and the test seam
            // (which bypass the attach pipeline) this is the only place
            // ordering is established, so first-emit becomes the slot.
            if source != "general" && !attachedAdapterOrder.contains(source) {
                attachedAdapterOrder.append(source)
            }
        }
        applyBehaviorsRecompute()
    }

    private func applyBehaviorsRecompute() {
        let merged = mergeBehaviors()
        context = SenseContext(
            app: context.app,
            window: context.window,
            behaviors: merged,
            permissions: context.permissions
        )
    }

    private func mergeBehaviors() -> [BehaviorEnvelope] {
        var out: [BehaviorEnvelope] = []
        if let general = behaviorsBySource["general"] {
            out.append(contentsOf: general)
        }
        // Adapters in attach order — pinned to registry registration order
        // by `attachAdaptersForCurrentApp`. Iterating Dictionary directly
        // would surface adapter chips in an unstable order across app
        // switches.
        for id in attachedAdapterOrder {
            if let envelopes = behaviorsBySource[id] {
                out.append(contentsOf: envelopes)
            }
        }
        return out
    }

    private func applyPermissions(_ permissions: PermissionState) {
        let oldDenied = context.permissions.denied
        context = SenseContext(
            app: context.app,
            window: context.window,
            behaviors: context.behaviors,
            permissions: permissions
        )

        let axNowGranted = oldDenied.contains(.accessibility)
            && !permissions.denied.contains(.accessibility)
        let axNowRevoked = !oldDenied.contains(.accessibility)
            && permissions.denied.contains(.accessibility)

        if axNowGranted, let pid = context.app?.pid {
            generalProbe?.attach(pid: pid)
        }
        if axNowRevoked {
            generalProbe?.detach()
            if let pid = context.app?.pid {
                hub.detach(pid: pid)
            }
        }
        // Keep WindowMirror's AX-side hookup in sync. Re-emits with AX-
        // resolved or degraded window as appropriate.
        if axNowGranted || axNowRevoked {
            windowMirror?.setAccessibilityGranted(!permissions.denied.contains(.accessibility))
        }

        // Re-run the adapter swap whenever the denied set actually
        // changed. This closes the permission-isolation contract on the
        // adapter side: an adapter whose `requiredPermissions` was just
        // unblocked attaches on this tick; one whose required permission
        // was just revoked detaches. Without this, an adapter declaring
        // `requiredPermissions != []` would be skipped at startup and
        // never re-attempt — `attachAdaptersForCurrentApp` is the only
        // path that calls `attach()`.
        if oldDenied != permissions.denied {
            scheduleAdapterSwap()
        }
    }

    /// Re-arm Observable tracking of `permissionsService.state`. Each fire
    /// re-applies the state and re-arms the tracker for the next change.
    private func observePermissions() {
        withObservationTracking {
            _ = permissionsService.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyPermissions(self.permissionsService.state)
                self.observePermissions()
            }
        }
    }

    // MARK: - Adapter swap pipeline
    //
    // Each frontmost change kicks off an async swap: detach previous
    // adapters, then attach all adapters matching the new bundle id. Swaps
    // are chained through `pendingSwap` so an in-flight detach can't race
    // with the next attach — the cost is a few extra ms when the user
    // app-switches rapidly, the win is no torn adapter state.

    private func scheduleAdapterSwap() {
        let previous = pendingSwap
        pendingSwap = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.detachAllAdapters()
            await self.attachAdaptersForCurrentApp()
        }
    }

    private func scheduleAdapterDetachAll() {
        let previous = pendingSwap
        pendingSwap = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.detachAllAdapters()
        }
    }

    private func detachAllAdapters() async {
        let toDetach = attachedAdapters
        let tasks = adapterTasks
        attachedAdapters.removeAll()
        adapterTasks.removeAll()
        attachedAdapterOrder.removeAll()

        // Drop each adapter's contribution from the merged behaviors view
        // immediately so the UI doesn't show stale chips.
        var changed = false
        for id in toDetach.keys where behaviorsBySource[id] != nil {
            behaviorsBySource.removeValue(forKey: id)
            changed = true
        }
        if changed {
            applyBehaviorsRecompute()
        }

        // Cancel consumer tasks first so we stop reading from streams the
        // adapter is about to tear down.
        for (_, task) in tasks { task.cancel() }

        // Tell each adapter to release its hub subscriptions. Run in
        // parallel — adapters are independent and detach() should be
        // quick.
        await withTaskGroup(of: Void.self) { group in
            for (_, adapter) in toDetach {
                group.addTask { await adapter.detach() }
            }
        }
    }

    private func attachAdaptersForCurrentApp() async {
        guard let app = context.app else { return }
        let bundleId = app.bundleId
        let target = RunningApp(bundleId: bundleId, pid: app.pid)
        let denied = context.permissions.denied
        let candidates = await registry.adapters(matching: bundleId)
        let hubRef = self.hub

        for adapter in candidates {
            let required = await adapter.requiredPermissions
            // Permission isolation: skip attach when any required permission
            // is currently denied (design §"权限隔离"). The store re-runs
            // this swap from `applyPermissions` whenever the denied set
            // changes, so denied→granted automatically triggers attach
            // and granted→denied automatically triggers detach.
            guard required.isDisjoint(with: denied) else { continue }
            let id = type(of: adapter).id
            // 500ms diagnostic timeout. Per `SenseAdapter` doc, attach
            // MUST return promptly; we log + count violations rather than
            // trying to engineer around them. See `withAttachTimeout` for
            // why we don't attempt a forced kill.
            let result = await self.withAttachTimeout(
                milliseconds: 500,
                adapterId: id,
                attach: { await adapter.attach(hub: hubRef, target: target) }
            )
            guard let stream = result else { continue }

            attachedAdapters[id] = adapter
            attachedAdapterOrder.append(id)
            let consumer = Task { [weak self] in
                for await envelopes in stream {
                    if Task.isCancelled { return }
                    guard let self else { return }
                    self.applyBehaviors(source: id, envelopes: envelopes)
                }
            }
            adapterTasks[id] = consumer
        }
    }

    /// Race the adapter's `attach` call against a 500ms sleep. **The
    /// timeout is diagnostic, not an enforcement mechanism.** Swift task
    /// cancellation is cooperative — if `attach` blocks on a synchronous
    /// AX or Apple Event call (which doesn't honor cancellation), we
    /// can't kill it; `cancelAll` only marks the task. The whole
    /// `withTaskGroup` then waits for both child tasks to finish anyway,
    /// because the group implicitly awaits all children before returning.
    ///
    /// What we DO get from the race:
    ///   - **Cooperative case (the contract):** `attach` returns within
    ///     a few ms; we get the stream and move on. Sleep loses, gets
    ///     cancelled cooperatively, group closes immediately.
    ///   - **Cancellation-aware-but-slow case:** `attach` is honoring
    ///     cancellation but for some reason exceeded 500ms; sleep wins,
    ///     `cancelAll` fires, the attach task observes cancellation and
    ///     returns. We log + bump the counter; the swap chain continues.
    ///   - **Contract-violating case:** `attach` is uncancellable
    ///     (synchronous AX, ignored Task.isCancelled). The sleep finishes
    ///     first, but `withTaskGroup` waits for the attach task anyway
    ///     before returning. We still log + bump the counter so the
    ///     violation is observable; but the swap chain blocks until the
    ///     adapter finally returns. This is documented as an adapter bug
    ///     — fixing it engineering-side would require leaking detached
    ///     tasks, which is worse than a loud, observable stall.
    private func withAttachTimeout(
        milliseconds: Int,
        adapterId: AdapterID,
        attach: @escaping @Sendable () async -> AsyncStream<[BehaviorEnvelope]>
    ) async -> AsyncStream<[BehaviorEnvelope]>? {
        let start = ContinuousClock.now
        let result = await withTaskGroup(of: AsyncStream<[BehaviorEnvelope]>?.self) { group -> AsyncStream<[BehaviorEnvelope]>? in
            group.addTask { await attach() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let elapsed = ContinuousClock.now - start
        if result == nil {
            attachTimeoutCount += 1
            Self.log.error(
                """
                SenseAdapter \(adapterId, privacy: .public) attach exceeded \
                \(milliseconds, privacy: .public)ms (elapsed: \
                \(elapsed.description, privacy: .public)). This is a \
                contract violation — see SenseAdapter.attach docs.
                """
            )
        } else if elapsed > .milliseconds(milliseconds / 2) {
            // Half the budget — not a violation, but worth knowing about.
            Self.log.notice(
                """
                SenseAdapter \(adapterId, privacy: .public) attach took \
                \(elapsed.description, privacy: .public) (budget: \
                \(milliseconds, privacy: .public)ms).
                """
            )
        }
        return result
    }

    // MARK: - Test seams (internal; reached via @testable import)

    internal func _applyFrontmostForTesting(app: AppIdentity?, window: WindowIdentity?) {
        applyFrontmost(app: app, window: window)
    }

    internal func _applyPermissionsForTesting(_ permissions: PermissionState) {
        applyPermissions(permissions)
    }

    internal func _applyBehaviorsForTesting(source: String, envelopes: [BehaviorEnvelope]) {
        applyBehaviors(source: source, envelopes: envelopes)
    }

    internal var _behaviorsBySourceForTesting: [String: [BehaviorEnvelope]] {
        behaviorsBySource
    }

    /// Test-only: wait for any in-flight adapter swap to complete. Lets
    /// tests assert post-swap state without sleeping.
    internal func _awaitPendingAdapterSwapForTesting() async {
        await pendingSwap?.value
    }

    internal var _attachedAdapterIdsForTesting: Set<AdapterID> {
        Set(attachedAdapters.keys)
    }

    /// Test-only: ordered view of attached adapters. Lets tests assert
    /// the registration-order invariant directly, instead of inferring
    /// it from `context.behaviors`.
    internal var _attachedAdapterOrderForTesting: [AdapterID] {
        attachedAdapterOrder
    }

    /// Test-only: how many times an adapter's `attach()` blew past the
    /// 500ms diagnostic timeout. Lets tests prove the observability seam
    /// without having to scrape OSLog.
    internal var _attachTimeoutCountForTesting: Int {
        attachTimeoutCount
    }
}
