import Foundation
import AppKit
import Combine

// MARK: - Event bridge
//
// Wires `EventMonitors.shared` into the NotchViewModel state machine, per
// notch-dev-guide.md §5.3 and notch-ui.md state-machine table.
//
// Subscriptions established here:
//   - mouseLocation → closed↔popping based on hot-rect containment
//   - mouseDown     → opened ↔ closed transitions
//   - keyDown ESC   → cancel + close
//
// The throttled haptic on entering .popping (§7.4) is no longer a Combine
// subscription — see `fireHapticIfNeeded()` below, called directly from
// `notchPop()`.

@MainActor
extension NotchViewModel {
    public func bindEvents(_ events: EventMonitors = .shared, agent: AgentService) {
        events.mouseLocation
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let p = NSEvent.mouseLocation
                let hot = self.closedHotRect
                if self.status == .closed, hot.contains(p) {
                    self.notchPop()
                } else if self.status == .popping, !hot.contains(p) {
                    self.notchClose()
                }
            }
            .store(in: &cancellables)

        events.mouseDown
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                let p = NSEvent.mouseLocation
                let hot = self.closedHotRect
                switch self.status {
                case .opened:
                    guard self.isAttachedTop else { return }
                    // Outside the visible silhouette → close. Re-click on
                    // the physical notch cutout → close. We use
                    // `notchOpenedTotalRect` (panel + tray) rather than
                    // just `notchOpenedRect` so clicks landing in the
                    // system-tray drawer reach SwiftUI buttons (× dismiss,
                    // chevron expand, "Open Settings") instead of being
                    // swallowed by this global mouse-down handler and
                    // triggering an unwanted close. We intentionally use
                    // `deviceNotchRect` (not the wider `closedHotRect`)
                    // for the re-click check because the top band of the
                    // opened panel hosts the header-strip buttons (gear,
                    // new conversation) right next to the cutout.
                    if Self.shouldCloseOpenedClick(
                        point: p,
                        isLocalNotchWindowEvent: event?.window is NotchWindow,
                        openedTotalRect: self.notchOpenedTotalRect,
                        deviceNotchRect: self.deviceNotchRect
                    ) {
                        self.notchClose()
                    }
                case .closed, .popping:
                    if hot.contains(p) {
                        self.notchOpen()
                    }
                }
            }
            .store(in: &cancellables)

        events.keyDown
            .receive(on: DispatchQueue.main)
            .sink { [weak self] keyCode in
                guard let self else { return }
                // 53 == ESC (kVK_Escape).
                guard keyCode == 53, self.status == .opened else { return }
                self.notchClose()
                Task { await agent.cancel() }
            }
            .store(in: &cancellables)
    }
}

// MARK: - Status / placement broadcast
//
// Direct typed callbacks (`onStatusChanged` / `onPlacementChanged`, declared
// on NotchViewModel) replace what used to be a NotificationCenter event bus.
// The view-model mutators (`notchOpen` / `notchClose` / `notchPop` /
// `setPlacement` / `openedSurfaceStateDidChange`) call `broadcastStatus()` /
// `broadcastPlacement()` after mutating; these just forward to the callback.

@MainActor
extension NotchViewModel {
    nonisolated static func shouldCloseOpenedClick(
        point: NSPoint,
        isLocalNotchWindowEvent: Bool,
        openedTotalRect: CGRect,
        deviceNotchRect: CGRect
    ) -> Bool {
        if isLocalNotchWindowEvent {
            return deviceNotchRect.contains(point)
        }
        return !openedTotalRect.contains(point) || deviceNotchRect.contains(point)
    }

    func broadcastStatus() {
        onStatusChanged?(status)
    }

    func broadcastPlacement() {
        onPlacementChanged?()
    }

    /// Haptic feedback on entering `.popping`, throttled to 0.5s so a jittery
    /// mouse over the notch doesn't spam the Taptic engine. Per notch-dev-guide
    /// §7.4. Leading edge fires immediately; repeats within the window are
    /// dropped — approximates Combine's `throttle(..., latest: false)`.
    func fireHapticIfNeeded() {
        let now = Date()
        if let last = lastPoppingHapticAt, now.timeIntervalSince(last) < 0.5 {
            return
        }
        lastPoppingHapticAt = now
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}
