import AppKit
import Foundation

// MARK: - SystemFocusStealPreventer
//
// Layer 3 of `FocusGuard`. Reactive defense against the failure mode where
// the target app calls `NSApp.activate(ignoringOtherApps:)` from its own
// `applicationDidFinishLaunching` (Calculator, several Electron shells,
// some AppKit apps).
//
// Mechanism — pure public AppKit, no private SPIs:
//
//   1. Subscribe to `NSWorkspace.didActivateApplicationNotification`.
//   2. When the newly-active pid matches an active suppression's
//      `targetPid`, schedule `restoreTo.activate(options: [])` on the
//      main actor with a zero-delay synchronous demote — completes
//      before WindowServer composites the next frame, so the user
//      never sees the flash.
//
// Multiple concurrent suppressions are supported: each
// `beginSuppression` returns a distinct handle and adds a row to the
// internal map. The shared `NSWorkspace` observer is installed on the
// first active suppression and torn down on the last.

public struct SuppressionHandle: Sendable, Hashable {
    fileprivate let id: UUID

    fileprivate init() {
        self.id = UUID()
    }
}

public actor SystemFocusStealPreventer {
    /// Was 300ms — empirically Chrome / similar apps had visible flashes
    /// for ~18 frames before we demoted. Zero-delay synchronous demote
    /// reliably completes before the next composited frame; keeps the
    /// target's pre-activation runloop work unaffected because the
    /// activation notification is async to begin with.
    private static let suppressionDelayNs: UInt64 = 0

    private let dispatcher: Dispatcher

    public init() {
        self.dispatcher = Dispatcher(suppressionDelayNs: Self.suppressionDelayNs)
    }

    @discardableResult
    public func beginSuppression(
        targetPid: pid_t,
        restoreTo: NSRunningApplication
    ) -> SuppressionHandle {
        let handle = SuppressionHandle()
        dispatcher.add(handle: handle, targetPid: targetPid, restoreTo: restoreTo)
        return handle
    }

    public func endSuppression(_ handle: SuppressionHandle) async {
        let pending = dispatcher.remove(handle: handle)
        for task in pending {
            _ = await task.value
        }
    }
}

// MARK: - Dispatcher
//
// Lock-protected observer state. Lives outside the actor because the
// `NSWorkspace` notification callback runs synchronously on the posting
// thread (typically main) — hopping into the actor first would push the
// reactivation Task scheduling further out, not closer in.

private final class Dispatcher: @unchecked Sendable {
    private struct Entry {
        let targetPid: pid_t
        let restoreTo: NSRunningApplication
    }

    private let suppressionDelayNs: UInt64
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var pendingRestoreTasks: [Task<Void, Never>] = []
    private var observer: NSObjectProtocol?

    init(suppressionDelayNs: UInt64) {
        self.suppressionDelayNs = suppressionDelayNs
    }

    func add(handle: SuppressionHandle, targetPid: pid_t, restoreTo: NSRunningApplication) {
        lock.lock()
        entries[handle.id] = Entry(targetPid: targetPid, restoreTo: restoreTo)
        let needsObserver = (observer == nil)
        lock.unlock()
        if needsObserver { installObserver() }
    }

    func remove(handle: SuppressionHandle) -> [Task<Void, Never>] {
        lock.lock()
        entries.removeValue(forKey: handle.id)
        let shouldRemoveObserver = entries.isEmpty
        let token = observer
        if shouldRemoveObserver { observer = nil }
        let pending = pendingRestoreTasks
        if shouldRemoveObserver { pendingRestoreTasks = [] }
        lock.unlock()

        if shouldRemoveObserver, let token {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        return pending
    }

    private func installObserver() {
        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            self?.handleActivation(note: note)
        }

        lock.lock()
        if observer == nil {
            observer = token
            lock.unlock()
        } else {
            // Race lost — somebody else installed first. Drop the duplicate.
            lock.unlock()
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    private func handleActivation(note: Notification) {
        guard
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        let activatedPid = app.processIdentifier

        lock.lock()
        let restoreCandidates = entries.values
            .filter { $0.targetPid == activatedPid }
            .map { $0.restoreTo }
        lock.unlock()

        guard let restoreTo = restoreCandidates.first else { return }

        let delayNs = suppressionDelayNs
        let task = Task.detached {
            try? await Task.sleep(nanoseconds: delayNs)
            await MainActor.run {
                _ = restoreTo.activate(options: [])
            }
        }
        lock.lock()
        pendingRestoreTasks.append(task)
        lock.unlock()
    }
}
