import AppKit
import Darwin
import Foundation

struct AXFocusSuppressionHandle: Sendable, Hashable {
    let rawValue: UInt64
}

struct AXFocusStealSuppression: Sendable {
    typealias Begin = @Sendable (pid_t, pid_t) async -> AXFocusSuppressionHandle
    typealias End = @Sendable (AXFocusSuppressionHandle) async -> Void

    let begin: Begin
    let end: End

    static func live() -> AXFocusStealSuppression {
        let preventer = AXFocusStealPreventer()
        return AXFocusStealSuppression(
            begin: { targetPid, restorePid in
                await preventer.beginSuppression(targetPid: targetPid, restorePid: restorePid)
            },
            end: { handle in
                await preventer.endSuppression(handle)
            }
        )
    }
}

actor AXFocusStealPreventer {
    typealias ActivationHandler = @Sendable (pid_t) -> Void
    typealias AddActivationObserver = @Sendable (@escaping ActivationHandler) -> @Sendable () -> Void
    typealias ActivateApplication = @Sendable (pid_t) async -> Bool
    typealias Sleep = @Sendable (UInt64) async throws -> Void

    private let dispatcher: AXFocusStealDispatcher
    private var nextHandle: UInt64 = 1

    init(
        addActivationObserver: @escaping AddActivationObserver = { handler in
            let token = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: nil
            ) { notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                    return
                }
                handler(app.processIdentifier)
            }
            let box = AXActivationObserverToken(token)
            return {
                NSWorkspace.shared.notificationCenter.removeObserver(box.token)
            }
        },
        activateApplication: @escaping ActivateApplication = { pid in
            await MainActor.run {
                NSRunningApplication(processIdentifier: pid)?.activate(options: []) ?? false
            }
        },
        sleep: @escaping Sleep = { delay in
            try await Task.sleep(nanoseconds: delay)
        }
    ) {
        self.dispatcher = AXFocusStealDispatcher(
            addActivationObserver: addActivationObserver,
            activateApplication: activateApplication,
            sleep: sleep,
            suppressionDelayNanoseconds: 0
        )
    }

    func beginSuppression(targetPid: pid_t, restorePid: pid_t) -> AXFocusSuppressionHandle {
        let handle = AXFocusSuppressionHandle(rawValue: nextHandle)
        nextHandle += 1
        dispatcher.add(handle: handle, targetPid: targetPid, restorePid: restorePid)
        return handle
    }

    func endSuppression(_ handle: AXFocusSuppressionHandle) async {
        let pending = dispatcher.remove(handle: handle)
        for task in pending {
            _ = await task.value
        }
    }
}

private final class AXFocusStealDispatcher: @unchecked Sendable {
    private struct Entry {
        let targetPid: pid_t
        let restorePid: pid_t
    }

    private let addActivationObserver: AXFocusStealPreventer.AddActivationObserver
    private let activateApplication: AXFocusStealPreventer.ActivateApplication
    private let sleep: AXFocusStealPreventer.Sleep
    private let suppressionDelayNanoseconds: UInt64
    private let lock = NSLock()
    private var entries: [AXFocusSuppressionHandle: Entry] = [:]
    private var pendingRestoreTasks: [Task<Void, Never>] = []
    private var removeObserver: (@Sendable () -> Void)?

    init(
        addActivationObserver: @escaping AXFocusStealPreventer.AddActivationObserver,
        activateApplication: @escaping AXFocusStealPreventer.ActivateApplication,
        sleep: @escaping AXFocusStealPreventer.Sleep,
        suppressionDelayNanoseconds: UInt64
    ) {
        self.addActivationObserver = addActivationObserver
        self.activateApplication = activateApplication
        self.sleep = sleep
        self.suppressionDelayNanoseconds = suppressionDelayNanoseconds
    }

    func add(handle: AXFocusSuppressionHandle, targetPid: pid_t, restorePid: pid_t) {
        lock.lock()
        entries[handle] = Entry(targetPid: targetPid, restorePid: restorePid)
        let needsObserver = removeObserver == nil
        lock.unlock()

        if needsObserver {
            installObserver()
        }
    }

    func remove(handle: AXFocusSuppressionHandle) -> [Task<Void, Never>] {
        lock.lock()
        entries.removeValue(forKey: handle)
        let shouldRemoveObserver = entries.isEmpty
        let remove = shouldRemoveObserver ? removeObserver : nil
        if shouldRemoveObserver {
            removeObserver = nil
        }
        let pending = shouldRemoveObserver ? pendingRestoreTasks : []
        if shouldRemoveObserver {
            pendingRestoreTasks = []
        }
        lock.unlock()

        remove?()
        return pending
    }

    private func installObserver() {
        let remove = addActivationObserver { [weak self] pid in
            self?.handleActivation(pid: pid)
        }

        lock.lock()
        if removeObserver == nil {
            removeObserver = remove
            lock.unlock()
        } else {
            lock.unlock()
            remove()
        }
    }

    private func handleActivation(pid activatedPid: pid_t) {
        lock.lock()
        let restorePid = entries.values.first { entry in
            entry.targetPid == activatedPid
        }?.restorePid
        lock.unlock()

        guard let restorePid else { return }

        let delay = suppressionDelayNanoseconds
        let sleep = sleep
        let activateApplication = activateApplication
        let task = Task.detached {
            try? await sleep(delay)
            _ = await activateApplication(restorePid)
        }

        lock.lock()
        pendingRestoreTasks.append(task)
        lock.unlock()
    }
}

private final class AXActivationObserverToken: @unchecked Sendable {
    let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) {
        self.token = token
    }
}
