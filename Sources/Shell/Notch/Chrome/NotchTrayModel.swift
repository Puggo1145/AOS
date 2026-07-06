import SwiftUI

// MARK: - NotchTrayModel
//
// Owns the tray/drawer concern: registered notice sources, dismissal
// bookkeeping, expansion state, and the drawer's measured-height policy.
// Extracted out of NotchViewModel so the drawer's composition rules can be
// exercised without the full service graph; see NotchTrayDismissalTests.
//
// The drawer pokes out from below the main panel when there are pending
// notices (permission gaps, missing provider, config-corruption notice).
// Dismissals are session-scoped — once the user closes a notice we stop
// surfacing it for the rest of the run. The underlying service signal is
// still authoritative for routing (onboarding, disabled input).

@MainActor
@Observable
public final class NotchTrayModel {
    /// Stable ids of tray items the user has dismissed this session.
    /// Sources are still asked for their current row on every render —
    /// the filter happens after composition, so the set survives a row
    /// flickering in and out (state churn won't reset dismissal).
    public var dismissedItemIds: Set<String> = [] {
        didSet { onStateChange?() }
    }
    public var trayExpanded: Bool = false {
        didSet { onStateChange?() }
    }
    public var trayContentHeight: CGFloat = 0 {
        didSet { onStateChange?() }
    }

    /// Registered tray-item sources, in registration order. Each is invoked
    /// on every `trayItems` read; empty returns are dropped silently.
    /// Mutated only via `registerTraySource(_:)` so the order is
    /// well-defined for the drawer (registration order = display order).
    private var traySources: [TraySource] = []

    /// Tray ceiling per design — taller lists scroll. Independent of the
    /// main panel's 480 budget; the NSWindow strip is sized to the sum.
    public let notchTrayMaxHeight: CGFloat = 240

    /// Collapsed-mode tray height (one row + container vertical padding).
    /// Hardcoded — tied to the SystemTrayView styling (11pt text + 6pt
    /// inner row + 10pt outer top/bottom padding ≈ 42pt).
    public let notchTrayCollapsedHeight: CGFloat = 42

    /// Slash-command palette short-circuit. Returns the palette's rows
    /// while it's active, `nil` when it isn't — `nil` means "compose the
    /// registered notice sources instead." Injected so this model doesn't
    /// need to know about `CommandPaletteState` or the composer.
    private var paletteItems: @MainActor () -> [TrayItem]?

    /// Fired after a dismissal is recorded, with the dismissed id. The
    /// config-corruption notice needs a server-side acknowledgement
    /// (`ConfigService.dismissCorruptionNotice()`) alongside the local
    /// dismissed-set write; routing that through a hook keeps this model
    /// free of a `ConfigService` dependency. Simpler seam than a second
    /// injected id-to-service-call table for what is, today, exactly one
    /// case.
    private var onDismiss: @MainActor (String) -> Void

    /// Mutation hook so detached-placement window resize still fires when
    /// tray state changes size. NotchViewModel wires this to
    /// `openedSurfaceStateDidChange()`.
    public var onStateChange: (@MainActor () -> Void)?

    public init(
        paletteItems: @escaping @MainActor () -> [TrayItem]?,
        onDismiss: @escaping @MainActor (String) -> Void
    ) {
        self.paletteItems = paletteItems
        self.onDismiss = onDismiss
    }

    /// Rewires the palette/dismiss hooks after construction. NotchViewModel
    /// needs this: the real closures capture `self`, which Swift's two-phase
    /// init forbids until every stored property (including `tray` itself)
    /// already has a value, so the viewmodel constructs `tray` with inert
    /// closures first and reconfigures it once its own init body has
    /// assigned every property.
    public func configure(
        paletteItems: @escaping @MainActor () -> [TrayItem]?,
        onDismiss: @escaping @MainActor (String) -> Void
    ) {
        self.paletteItems = paletteItems
        self.onDismiss = onDismiss
    }

    /// Append a tray-item source. Sources are invoked on every render of
    /// `trayItems`; they should be cheap, deterministic, and read from
    /// `@Observable` state so SwiftUI re-evaluates when the underlying
    /// signal changes. Sources cannot be removed today — registration
    /// happens at construction (or boot-time plugin install) and survives
    /// for the process lifetime; if dynamic register/unregister is needed
    /// later, swap the array for a `[String: TraySource]` keyed by source id.
    public func registerTraySource(_ source: @escaping TraySource) {
        traySources.append(source)
    }

    /// Active drawer rows. Composes every registered source, then drops
    /// rows whose ids the user has dismissed. Source registration order
    /// is the display order — built-in system notices (permission /
    /// provider / config) are registered first, so they always render
    /// above later additions like the agent's todo-progress row.
    ///
    /// Slash-command palette short-circuits this composition: while the
    /// palette is active the drawer is the command palette's surface,
    /// not a notice list. Mixing system notices with command suggestions
    /// would dilute both — the user is mid-keystroke selecting a command,
    /// not triaging notices. Notices flip back the instant the palette
    /// gate fails (e.g. user types space, escapes, or executes).
    public var trayItems: [TrayItem] {
        if let paletteRows = paletteItems() {
            return paletteRows
        }
        var out: [TrayItem] = []
        for source in traySources {
            out.append(contentsOf: source())
        }
        if dismissedItemIds.isEmpty { return out }
        return out.filter { !dismissedItemIds.contains($0.id) }
    }

    /// Effective expansion state used by the tray view. Forced open
    /// while the slash-command palette is active so every match is
    /// visible without a chevron click — the user expects to see the
    /// suggestion list as soon as `/` is typed. Outside palette mode
    /// this is the user's stored preference.
    public var effectiveTrayExpanded: Bool {
        isCommandPaletteMode || trayExpanded
    }

    /// True iff the drawer is currently rendering slash-command rows
    /// (vs. ordinary notices). Used by SystemTrayView to drop the
    /// dismiss `×` and the collapsed/expanded chevron — neither has
    /// meaning during command selection.
    public var isCommandPaletteMode: Bool {
        paletteItems() != nil
    }

    public var hasTrayItems: Bool { !trayItems.isEmpty }

    /// Tray rect — width matches the main panel (passed in by the caller,
    /// which owns `notchOpenedWidth`).
    ///   • No notices → height 0 (drawer absent).
    ///   • One notice OR expanded → measured natural height, clamped into
    ///     [collapsedHeight, maxHeight]. Beyond maxHeight the inner ScrollView
    ///     takes over.
    ///   • Multi-notice + collapsed → hardcoded collapsed height (just the
    ///     first row); the additional rows are still in the layout but get
    ///     clipped by the parent frame for a clean "drawer extending"
    ///     animation rather than a fade.
    public func traySize(width: CGFloat) -> CGSize {
        NotchGeometryModel.makeTraySize(
            width: width,
            itemCount: trayItems.count,
            expanded: effectiveTrayExpanded,
            measuredContentHeight: trayContentHeight,
            collapsedHeight: notchTrayCollapsedHeight,
            maxHeight: notchTrayMaxHeight
        )
    }

    /// Hide a tray row for the rest of the session. Calling this with an
    /// id that's non-dismissable (e.g. live `agent.todoProgress`) is a
    /// no-op — the item's source is the lifecycle authority and re-emits
    /// the row on the next render regardless of the dismissed set; we
    /// still record the id so the contract is uniform, but `trayItems`
    /// deliberately does NOT filter non-dismissable rows by id (defensive:
    /// future callers can't accidentally hide live state by reusing this
    /// path).
    public func dismissTrayItem(id: String) {
        // Look up the row's dismissable flag from the current snapshot.
        // A row that doesn't currently exist is a no-op — we don't speculate
        // about whether it'll show up later.
        // Default `false` (not `true`) so a dismiss call against a row that
        // isn't currently visible is a true no-op. Otherwise a transiently
        // hidden source (toggles with state, plugin between renders) would
        // get its id silently recorded and filtered forever once it returns.
        let isDismissable = trayItems.first(where: { $0.id == id })?.dismissable ?? false
        guard isDismissable else { return }
        dismissedItemIds.insert(id)
        onDismiss(id)
        // If the drawer just emptied, reset the expansion so the next time
        // a row arrives it starts collapsed (matching the comment that
        // used to live on `dismissNotice`).
        if trayItems.isEmpty {
            trayExpanded = false
        }
    }

    public func toggleTrayExpanded() {
        trayExpanded.toggle()
    }
}
