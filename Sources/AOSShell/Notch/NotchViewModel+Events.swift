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
//   - status flip   → debounce-driven silhouette fade (notch-dev-guide §7.3)
//   - status flip   → throttled haptic on entering .popping (§7.4)

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
            .sink { [weak self] _ in
                guard let self else { return }
                let p = NSEvent.mouseLocation
                let hot = self.closedHotRect
                switch self.status {
                case .opened:
                    // Outside panel → close. Re-click on the physical notch
                    // cutout → close. We intentionally use `deviceNotchRect`
                    // here rather than the wider `closedHotRect` because the
                    // top band of the opened panel hosts the header-strip
                    // buttons (settings, new conversation) right next to the
                    // cutout; using the closed-bar rect would swallow those
                    // clicks and dismiss the panel before SwiftUI's button
                    // handler could fire.
                    if !self.notchOpenedRect.contains(p) || self.deviceNotchRect.contains(p) {
                        self.notchClose()
                    }
                case .closed, .popping:
                    if hot.contains(p) {
                        self.notchOpen(.click)
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

        // The closed-state silhouette stays fully opaque at all times — the
        // bar is the persistent "agent online" indicator that hugs the
        // physical notch, so any rest-state fade would expose the hardware
        // cutout and read as the UI disappearing.
        let statusPublisher = NotificationCenter.default
            .publisher(for: .aosNotchStatusChanged)
            .compactMap { $0.object as? NotchViewModel.Status }

        // Haptic feedback on entering .popping, throttled to 0.5s so a jittery
        // mouse over the notch doesn't spam the Taptic engine. Per §7.4.
        statusPublisher
            .filter { $0 == .popping }
            .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: false)
            .sink { _ in
                NSHapticFeedbackManager.defaultPerformer.perform(
                    .levelChange,
                    performanceTime: .now
                )
            }
            .store(in: &cancellables)
    }
}

// MARK: - Status broadcast
//
// We piggy-back on NotificationCenter to publish status changes for the
// debounce/throttle pipelines. The viewModel posts on every status mutation
// via `didSet`-equivalent; with @Observable we can't observe properties from
// Combine directly, so we route the notify call from a willSet hook in
// `notchOpen` / `notchClose` / `notchPop` (those mutators must broadcast).
//
// To keep the change centralized, we wrap them here in a notify helper. The
// view-model methods themselves call `broadcastStatus()` after mutating.

extension Notification.Name {
    static let aosNotchStatusChanged = Notification.Name("aos.notch.statusChanged")
}

@MainActor
extension NotchViewModel {
    func broadcastStatus() {
        NotificationCenter.default.post(name: .aosNotchStatusChanged, object: status)
    }
}
