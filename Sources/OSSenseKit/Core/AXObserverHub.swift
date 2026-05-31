import Foundation
import ApplicationServices
import AppKit

// MARK: - AXObserverHub
//
// Per `docs/designs/os-sense.md` §"共享 AX 底座" — every component that wants
// AX notifications goes through this hub. The hub owns one `AXObserver` per
// pid, shared across subscribers. When all subscriptions for a pid are gone
// (e.g. on app deactivate via `detach(pid:)`), the observer is removed from
// the runloop and released.
//
// Fan-out invariant: `AXObserverAddNotification` rejects re-registration of
// the same `(observer, element, notification)` triple with
// `kAXErrorNotificationAlreadyRegistered`. The hub therefore aggregates AX
// registrations by `(pid, element, notification)` and only calls `Add` once
// per triple. Each token is just a handle into the registration's handler
// table — multiple subscribers to the same triple all fan out from one AX
// notification.
//
// The hub is `@MainActor`-isolated because:
//   - AX callbacks fire on the runloop the observer was attached to (we use
//     the main runloop), so callbacks already arrive on the main thread.
//   - SenseStore + producers (GeneralProbe, adapters) are all @MainActor.
//   - Avoids actor-hop latency on every AX event.
//
// Token-based subscription model: `subscribe(...)` returns a token; the
// caller keeps the token and calls `unsubscribe(_:)` to tear down a single
// subscription. `detach(pid:)` is the bulk path used when an app leaves the
// foreground.
//
// `refcon` plumbing: AXObserverAddNotification takes a `void *` refcon that
// is passed back to the C callback. We pass a small opaque id, not a Swift
// object pointer. The callback maps that id through `activeRefcons` before
// touching Swift state, so queued callbacks that arrive after teardown can
// no-op without dereferencing retired heap objects. This keeps Swift closures
// from leaking into the C ABI seam (function pointers must be non-capturing).

@MainActor
public final class AXObserverHub {
    public typealias Token = UUID

    private var observers: [pid_t: AXObserver] = [:]
    /// Registered AX notifications, keyed by triple. Each entry holds the
    /// AX-level refcon id plus the fan-out handler table.
    private var registrations: [RegistrationKey: Registration] = [:]
    /// Reverse map so `unsubscribe(_:)` can find its registration in O(1).
    private var tokenIndex: [Token: RegistrationKey] = [:]
    /// AX may deliver a callback that was already queued before
    /// `AXObserverRemoveNotification` returned. Do not pass Swift object
    /// addresses through refcon: retired object pointers can be dereferenced by
    /// those stale callbacks. Instead, pass a small opaque id and look it up in
    /// this active table.
    private static var nextRefconID: Int = 1
    private static var activeRefcons: [Int: RefconBox] = [:]

    public init() {}

    /// Subscribe to `notification` for `element` under `pid`. The hub creates
    /// (or reuses) the per-pid observer, and registers the notification with
    /// AX exactly once per `(pid, element, notification)` triple — additional
    /// subscribers to the same triple fan out from that single registration.
    /// Returns nil iff `AXObserverCreate` or `AXObserverAddNotification` fail
    /// (typically: missing Accessibility permission, or `element` is no
    /// longer alive on the other side of the AX seam).
    public func subscribe(
        pid: pid_t,
        element: AXUIElement,
        notification: String,
        handler: @escaping @MainActor () -> Void
    ) -> Token? {
        let observer = ensureObserver(forPid: pid)
        guard let observer else { return nil }

        let key = RegistrationKey(pid: pid, element: element, notification: notification)
        let token = Token()

        if let existing = registrations[key] {
            // Already registered with AX. Just fan out one more handler.
            existing.handlers[token] = handler
            tokenIndex[token] = key
            return token
        }

        // First subscriber for this triple — register with AX once, attaching
        // a refcon that points back to this Registration so the C callback
        // can fan out to every handler.
        let registration = Registration(
            pid: pid,
            element: element,
            notification: notification
        )
        let refconID = Self.activateRefcon(hub: self, key: key)
        registration.refconID = refconID

        let addErr = AXObserverAddNotification(
            observer,
            element,
            notification as CFString,
            Self.refconPointer(for: refconID)
        )
        guard addErr == .success else {
            Self.deactivateRefcon(id: refconID)
            registration.refconID = nil
            // If we just spun up the observer for this pid, retire it so the
            // observers map stays honest.
            retireObserverIfUnused(pid: pid)
            return nil
        }

        registration.handlers[token] = handler
        registrations[key] = registration
        tokenIndex[token] = key
        return token
    }

    /// Tear down a single subscription. No-op if the token is unknown. When
    /// the last handler for a `(pid, element, notification)` triple goes
    /// away, the AX registration itself is released; when a pid has no more
    /// triples at all, the per-pid observer is removed from the runloop.
    public func unsubscribe(_ token: Token) {
        guard let key = tokenIndex.removeValue(forKey: token),
              let registration = registrations[key] else { return }
        registration.handlers.removeValue(forKey: token)
        guard registration.handlers.isEmpty else { return }

        // Last handler gone — retire the AX-level registration.
        if let observer = observers[key.pid] {
            AXObserverRemoveNotification(
                observer,
                registration.element,
                registration.notification as CFString
            )
        }
        deactivateRefcon(for: registration)
        registrations.removeValue(forKey: key)
        retireObserverIfUnused(pid: key.pid)
    }

    /// Detach all subscriptions for `pid` and release the observer. Used by
    /// SenseStore / probes when the app leaves the foreground.
    public func detach(pid: pid_t) {
        let toRemove = registrations.compactMap { $0.key.pid == pid ? $0.key : nil }
        guard !toRemove.isEmpty else {
            // No registrations for this pid — still ensure the observer (if
            // somehow created without a registration) gets retired.
            retireObserverIfUnused(pid: pid)
            return
        }
        let observer = observers[pid]
        for key in toRemove {
            guard let registration = registrations.removeValue(forKey: key) else { continue }
            for token in registration.handlers.keys {
                tokenIndex.removeValue(forKey: token)
            }
            if let observer {
                AXObserverRemoveNotification(
                    observer,
                    registration.element,
                    registration.notification as CFString
                )
            }
            deactivateRefcon(for: registration)
        }
        retireObserverIfUnused(pid: pid)
    }

    /// Test-only: count of live subscriptions (handler tokens, not AX
    /// registrations — that's what the rest of the system reasons about).
    internal var subscriptionCount: Int { tokenIndex.count }
    internal func subscriptionCount(forPid pid: pid_t) -> Int {
        tokenIndex.values.filter { $0.pid == pid }.count
    }
    /// Test-only: count of distinct AX-level registrations. Lets tests prove
    /// fan-out works (N tokens on the same triple → 1 registration).
    internal var registrationCount: Int { registrations.count }

    /// Test-only: synthesize a callback dispatch for a given `(pid, element,
    /// notification)` registration. Real AX callbacks come from the system,
    /// which tests can't drive; this seam exercises fan-out logic.
    internal func _dispatchForTesting(
        pid: pid_t,
        element: AXUIElement,
        notification: String
    ) {
        let key = RegistrationKey(pid: pid, element: element, notification: notification)
        guard let registration = registrations[key] else { return }
        for handler in registration.handlers.values {
            handler()
        }
    }

    /// Test-only: install a subscription without touching AX. Lets fan-out
    /// and lifecycle invariants be exercised in environments where the test
    /// process can't successfully `AXObserverCreate` (no Accessibility
    /// permission, no real target process). The behavior of `unsubscribe` /
    /// `detach` is identical except for the AX-side calls, which are no-ops
    /// when no observer was created for the pid.
    internal func _subscribeWithoutAXForTesting(
        pid: pid_t,
        element: AXUIElement,
        notification: String,
        handler: @escaping @MainActor () -> Void
    ) -> Token {
        let key = RegistrationKey(pid: pid, element: element, notification: notification)
        let token = Token()
        if let existing = registrations[key] {
            existing.handlers[token] = handler
            tokenIndex[token] = key
            return token
        }
        let registration = Registration(pid: pid, element: element, notification: notification)
        registration.handlers[token] = handler
        registrations[key] = registration
        tokenIndex[token] = key
        return token
    }

    /// Test-only: create a registration with the same refcon shape used by the
    /// production AX registration path, but without calling into AX. This lets
    /// tests drive stale-callback lifecycle behavior deterministically.
    internal func _subscribeWithCallbackRefconForTesting(
        pid: pid_t,
        element: AXUIElement,
        notification: String,
        handler: @escaping @MainActor () -> Void
    ) -> Token {
        let key = RegistrationKey(pid: pid, element: element, notification: notification)
        let token = Token()
        if let existing = registrations[key] {
            existing.handlers[token] = handler
            tokenIndex[token] = key
            return token
        }
        let registration = Registration(pid: pid, element: element, notification: notification)
        registration.refconID = Self.activateRefcon(hub: self, key: key)
        registration.handlers[token] = handler
        registrations[key] = registration
        tokenIndex[token] = key
        return token
    }

    internal func _refconForTesting(
        pid: pid_t,
        element: AXUIElement,
        notification: String
    ) -> UnsafeMutableRawPointer? {
        let key = RegistrationKey(pid: pid, element: element, notification: notification)
        guard let id = registrations[key]?.refconID else { return nil }
        return Self.refconPointer(for: id)
    }

    internal static func _dispatchCallbackForTesting(refcon: UnsafeMutableRawPointer?) {
        dispatchCallback(refcon: refcon)
    }

    // MARK: - Internals

    private func ensureObserver(forPid pid: pid_t) -> AXObserver? {
        if let existing = observers[pid] { return existing }
        var newObserver: AXObserver?
        let err = AXObserverCreate(pid, Self.axCallback, &newObserver)
        guard err == .success, let observer = newObserver else { return nil }
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
        observers[pid] = observer
        return observer
    }

    private func retireObserverIfUnused(pid: pid_t) {
        guard !registrations.keys.contains(where: { $0.pid == pid }) else { return }
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
    }

    private func deactivateRefcon(for registration: Registration) {
        guard let id = registration.refconID else { return }
        Self.deactivateRefcon(id: id)
        registration.refconID = nil
    }

    private static func activateRefcon(hub: AXObserverHub, key: RegistrationKey) -> Int {
        let id = nextRefconID
        nextRefconID += 1
        activeRefcons[id] = RefconBox(hub: hub, key: key)
        return id
    }

    private static func deactivateRefcon(id: Int) {
        activeRefcons.removeValue(forKey: id)
    }

    private static func refconPointer(for id: Int) -> UnsafeMutableRawPointer {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: id) else {
            preconditionFailure("AXObserverHub refcon id must never be zero")
        }
        return pointer
    }

    /// Keys an AX registration by its triple. AXUIElement is a CF-bridged
    /// opaque type; use `CFHash` / `CFEqual` for value-based identity so two
    /// reads of the same UI element compare equal even if they came back as
    /// distinct AX references.
    private struct RegistrationKey: Hashable {
        let pid: pid_t
        let element: AXUIElement
        let notification: String

        func hash(into hasher: inout Hasher) {
            hasher.combine(pid)
            hasher.combine(CFHash(element))
            hasher.combine(notification)
        }

        static func == (lhs: RegistrationKey, rhs: RegistrationKey) -> Bool {
            lhs.pid == rhs.pid
                && lhs.notification == rhs.notification
                && CFEqual(lhs.element, rhs.element)
        }
    }

    private final class Registration {
        let pid: pid_t
        let element: AXUIElement
        let notification: String
        var handlers: [Token: @MainActor () -> Void] = [:]
        /// Opaque id passed through AX's `void *` refcon. The id is removed
        /// from `activeRefcons` when the AX registration is retired, so stale
        /// callbacks cannot dereference released Swift objects.
        var refconID: Int?

        init(pid: pid_t, element: AXUIElement, notification: String) {
            self.pid = pid
            self.element = element
            self.notification = notification
        }
    }

    private final class RefconBox {
        weak var hub: AXObserverHub?
        let key: RegistrationKey
        init(hub: AXObserverHub, key: RegistrationKey) {
            self.hub = hub
            self.key = key
        }
    }

    /// Non-capturing C function pointer required by AXObserverAddNotification.
    /// Resolves the registration from refcon and fans out to every handler on
    /// the main thread (already where we are: the observer source was added
    /// to the main runloop).
    private static let axCallback: AXObserverCallback = { _, _, _, refcon in
        dispatchCallback(refcon: refcon)
    }

    private nonisolated static func dispatchCallback(refcon: UnsafeMutableRawPointer?) {
        guard let refcon else { return }
        // We're on the main runloop because that's where the observer source
        // was registered. assumeIsolated avoids a Task hop that would lose
        // the synchronous "callback fires before AX returns" ordering.
        MainActor.assumeIsolated {
            let id = Int(bitPattern: refcon)
            guard let box = activeRefcons[id] else { return }
            guard let hub = box.hub,
                  let registration = hub.registrations[box.key] else { return }
            for handler in registration.handlers.values {
                handler()
            }
        }
    }
}
