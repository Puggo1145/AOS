import SwiftUI

// MARK: - TrayItem
//
// Generic row model rendered by `SystemTrayView` (the drawer hanging below
// the main notch panel). Replaces the previous closed `SystemNotice` enum
// so any subsystem can register its own row without editing the view.
//
// Two consumer-visible variants of the right-side slot:
//   - `.action`  — a CTA label (e.g. "Open Settings"). Whole row is
//                  tappable when the item carries an `onTap`.
//   - `.badge`   — a numeric / status badge (e.g. "3/5"). Renders in a
//                  monospaced face so digits don't jitter as the badge
//                  updates between renders.
//
// Identity is a stable string namespaced by source ("system.*", "agent.*",
// future "skill.*", etc.). Used by:
//   - `ForEach`   — diff key for animation continuity.
//   - dismissal   — the viewmodel records dismissed ids in a `Set<String>`.
//   - tests       — assertions against the visible tray content.
//
// Closure properties (`onTap`) intentionally drop `Sendable`/`Equatable`
// conformance from the struct. Equality compares only the visible, value-
// like fields so tests can `#expect(item == reference)` without rebuilding
// closures; the synthesized comparison would have refused to compile.

@MainActor
public struct TrayItem: Identifiable {
    public let id: String
    public let icon: String
    public let tint: Color
    public let message: String
    /// Right-side label. `nil` for rows that are pure message + dismiss.
    public let trailing: TrayItemTrailing?
    /// `false` hides the dismiss `×` button. Live-state rows (e.g. agent
    /// progress) set this so the row's lifecycle stays driven by its
    /// source rather than user preference.
    public let dismissable: Bool
    /// Whole-row tap handler. When non-nil the row renders as a Button so
    /// VoiceOver / Voice Control / keyboard activation all work — match
    /// the pre-refactor system-notice CTA behaviour. `nil` means the row
    /// is purely informational.
    public let onTap: (@MainActor () -> Void)?

    public init(
        id: String,
        icon: String,
        tint: Color,
        message: String,
        trailing: TrayItemTrailing? = nil,
        dismissable: Bool = true,
        onTap: (@MainActor () -> Void)? = nil
    ) {
        self.id = id
        self.icon = icon
        self.tint = tint
        self.message = message
        self.trailing = trailing
        self.dismissable = dismissable
        self.onTap = onTap
    }
}

public enum TrayItemTrailing: Equatable, Sendable {
    /// CTA label rendered in the regular UI font. Pair with an `onTap` on
    /// the owning `TrayItem` to make the row activate the action.
    case action(String)
    /// Status badge rendered in monospaced digits. No tap behaviour.
    case badge(String)

    var label: String {
        switch self {
        case .action(let s): return s
        case .badge(let s): return s
        }
    }
}

// MARK: - Tray source
//
// A `TraySource` is a closure invoked on every `trayItems` read. Returning
// an empty array means "I have nothing to show right now"; returning a
// non-empty array adds those rows in the source's preferred order. The
// viewmodel concatenates sources in registration order, then filters out
// any row whose id has been dismissed.
//
// Sources are intended to be cheap pure functions of @Observable state —
// the viewmodel doesn't cache results. If a source needs to do real work
// (network, disk) it should compute the trayItem off-thread and surface a
// `@Observable` snapshot the closure can read synchronously.

public typealias TraySource = @MainActor () -> [TrayItem]

/// Stable id constants for the built-in sources. External plugins should
/// pick their own namespaces (e.g. `"skill.<name>"`) so dismissal sets and
/// SwiftUI diff keys never collide.
public enum BuiltinTrayItemID {
    public static let missingPermission = "system.missingPermission"
    public static let missingProvider = "system.missingProvider"
    public static let configCorruption = "system.configCorruption"
    public static let todoProgress = "agent.todoProgress"
}
