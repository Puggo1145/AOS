import Foundation
import AppKit
import SwiftUI
import Combine
import AOSOSSenseKit

// MARK: - System tray notice model
//
// Surfaces in the drawer that pokes out from below the main panel. Each kind
// is derived from a service signal (permission missing, no provider, config
// reset). Dismissing is session-scoped — the user can hide a notice for the
// remainder of the run; the underlying condition still drives onboarding /
// inline-disabled-input behaviour.

// `TrayItem` and `TraySource` live in `Notch/Components/TrayItem.swift`.
// The viewmodel composes registered sources into a single `trayItems`
// array consumed by `SystemTrayView`. Built-in system notices and the
// agent's live `todoProgress` row are themselves sources installed in
// `init` — there is no privileged path for them.

// MARK: - NotchViewModel
//
// Owns the Notch UI state machine + derived geometry per docs/designs/notch-ui.md.
//
// Holds (read-only) references to `SenseStore` and `AgentService` so the
// SwiftUI views can read context + agent state through one entry point.
// All mutation flows through @MainActor methods.

@MainActor
@Observable
public final class NotchViewModel {
    public enum Status: Sendable, Equatable {
        case closed
        case popping
        case opened
    }

    public enum OpenReason: Sendable, Equatable {
        case click
        case boot
        case unknown
    }

    // MARK: - Stored state

    public private(set) var status: Status = .closed
    public var openReason: OpenReason = .unknown
    public var screenRect: CGRect
    public var deviceNotchRect: CGRect
    public var inputFocused: Bool = false
    /// Settings panel overlay. Reachable from the gear button in
    /// OpenedPanelView; reset to false on close.
    public var showSettings: Bool = false

    // MARK: - Constants

    /// Width is fixed; height grows with the conversation while the agent
    /// loop is active. `compactMin` is a floor — the panel is never shorter
    /// than this even if the composer measures smaller (avoids the silhouette
    /// flickering on first frame before measurements arrive). `max` is the
    /// hosting NSWindow's strip height — the silhouette never grows past it,
    /// instead the history ScrollView starts scrolling.
    public let notchOpenedWidth: CGFloat = 500
    public let notchOpenedCompactMinHeight: CGFloat = 100
    public let notchOpenedMaxHeight: CGFloat = 480

    /// Measured natural height of whichever onboarding panel is currently
    /// rendered (PermissionOnboardPanelView or OnboardPanelView). Reported
    /// up via PreferenceKey so the silhouette hugs the panel's intrinsic
    /// size — without this the panel falls back to `compactMin` and the
    /// cards collide with the tray drawer below.
    public var onboardingContentHeight: CGFloat = 0

    /// Measured natural height of SettingsPanelView. Same content-driven
    /// pattern as onboarding: PreferenceKey reports the intrinsic height,
    /// `notchOpenedSize` clamps it into [compactMin, max]. Adding/removing
    /// rows in Settings no longer needs a hand-tuned constant.
    public var settingsContentHeight: CGFloat = 0

    /// Measured natural height of SessionHistoryPanelView. Same content-driven
    /// pattern as Settings: PreferenceKey reports the intrinsic height,
    /// `notchOpenedSize` clamps it into [compactMin, max]; the inner
    /// ScrollView takes over once the list exceeds the ceiling.
    public var historyPanelContentHeight: CGFloat = 0

    /// Vertical chrome around the dynamic content inside OpenedPanelView:
    /// top safe inset + spacing(8) between history and composer + bottom
    /// padding(16). Kept here so `notchOpenedSize` can clamp the panel's
    /// natural size without re-deriving the layout's paddings.
    public var openedContentVerticalChrome: CGFloat {
        deviceNotchRect.height + 8 + 16
    }

    /// Measured natural heights of the two stacks inside OpenedPanelView.
    /// The view writes these via PreferenceKey on every layout pass; we
    /// derive `notchOpenedSize.height` from them so the silhouette grows
    /// alongside the streamed reply, capped at `notchOpenedMaxHeight`.
    public var historyContentHeight: CGFloat = 0
    public var composerContentHeight: CGFloat = 0

    // MARK: - System tray (drawer) state
    //
    // The drawer pokes out from below the main panel when there are pending
    // notices (permission gaps, missing provider, config-corruption notice).
    // Dismissals are session-scoped — once the user closes a notice we stop
    // surfacing it for the rest of the run. The underlying service signal
    // is still authoritative for routing (onboarding, disabled input).

    /// Stable ids of tray items the user has dismissed this session.
    /// Sources are still asked for their current row on every render —
    /// the filter happens after composition, so the set survives a row
    /// flickering in and out (state churn won't reset dismissal).
    public var dismissedItemIds: Set<String> = []
    public var trayExpanded: Bool = false
    public var trayContentHeight: CGFloat = 0

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

    /// Active drawer rows. Composes every registered source, then drops
    /// rows whose ids the user has dismissed. Source registration order
    /// is the display order — built-in system notices (permission /
    /// provider / config) are registered first in `init`, so they always
    /// render above later additions like the agent's todo-progress row.
    public var trayItems: [TrayItem] {
        var out: [TrayItem] = []
        for source in traySources {
            out.append(contentsOf: source())
        }
        if dismissedItemIds.isEmpty { return out }
        return out.filter { !dismissedItemIds.contains($0.id) }
    }

    public var hasTrayItems: Bool { !trayItems.isEmpty }

    /// Append a tray-item source. Sources are invoked on every render of
    /// `trayItems`; they should be cheap, deterministic, and read from
    /// `@Observable` state so SwiftUI re-evaluates when the underlying
    /// signal changes. Sources cannot be removed today — registration
    /// happens at viewmodel construction (or boot-time plugin install)
    /// and survives for the process lifetime; if dynamic
    /// register/unregister is needed later, swap the array for a
    /// `[String: TraySource]` keyed by source id.
    public func registerTraySource(_ source: @escaping TraySource) {
        traySources.append(source)
    }

    /// Tray rect — width matches the main panel.
    ///   • No notices → height 0 (drawer absent).
    ///   • One notice OR expanded → measured natural height, clamped into
    ///     [collapsedHeight, maxHeight]. Beyond maxHeight the inner ScrollView
    ///     takes over.
    ///   • Multi-notice + collapsed → hardcoded collapsed height (just the
    ///     first row); the additional rows are still in the layout but get
    ///     clipped by the parent frame for a clean "drawer extending"
    ///     animation rather than a fade.
    public var notchTraySize: CGSize {
        Self.makeTraySize(
            width: notchOpenedWidth,
            itemCount: trayItems.count,
            expanded: trayExpanded,
            measuredContentHeight: trayContentHeight,
            collapsedHeight: notchTrayCollapsedHeight,
            maxHeight: notchTrayMaxHeight
        )
    }

    /// Combined bounding box of main panel + tray. Drives the window strip
    /// height and the click-through hot rect when opened.
    public var notchOpenedTotalSize: CGSize {
        let main = notchOpenedSize
        let tray = notchTraySize
        return CGSize(width: main.width, height: main.height + tray.height)
    }

    public var notchOpenedTotalRect: CGRect {
        Self.makeOpenedTotalRect(screenRect: screenRect, totalSize: notchOpenedTotalSize)
    }

    /// Composes the localised permission-missing message used by the tray.
    /// Mirrors the previous in-OpenedPanelView helper so the notice text is
    /// identical to what the inline banner used to render.
    private var missingPermissionMessage: String {
        let denied = permissionsService.state.denied
        if denied.contains(.screenRecording) && denied.contains(.accessibility) {
            return "Screen Recording & Accessibility disabled"
        }
        if denied.contains(.screenRecording) { return "Screen Recording disabled" }
        if denied.contains(.accessibility)    { return "Accessibility disabled" }
        return "A required permission is disabled"
    }

    /// True while NotchView is showing one of the first-run onboarding
    /// panels (permission gate or provider sign-in). Mirrors the branch
    /// conditions in `NotchView.openedContent` so `notchOpenedSize` can
    /// reserve enough vertical space for the cards. Once the latch
    /// `hasCompletedOnboarding` flips, post-onboarding permission/provider
    /// drops surface inline and this stays false.
    public var isOnboarding: Bool {
        guard !configService.hasCompletedOnboarding else { return false }
        return !permissionsService.allGranted || !providerService.hasReadyProvider
    }

    /// True iff the *currently selected* provider is in `.ready`. Drives the
    /// composer's enabled state — `hasReadyProvider` (any-ready) is too loose:
    /// it lets the user submit a turn against an unauthenticated provider
    /// just because some other provider happens to be authed.
    public var selectedProviderReady: Bool {
        guard let id = configService.effectiveSelection?.providerId else { return false }
        return providerService.providers.contains { $0.id == id && $0.state == .ready }
    }

    /// True iff the composer should accept input AND submit. Composes two
    /// independent gates: the selected provider is authed, AND the session
    /// bootstrap succeeded. Bootstrap failure is rare but fatal for the
    /// agent loop — there's no active session to attach a turn to, so
    /// submit would silently no-op without this guard.
    public var composerSubmitEnabled: Bool {
        guard selectedProviderReady else { return false }
        return agentService.sessionStore.bootError == nil
    }

    public var notchOpenedSize: CGSize {
        // Settings: drive the silhouette off the panel's measured intrinsic
        // height (same pattern as onboarding), so adding/removing rows just
        // flows through. Picker sub-pages exceeding the max ceiling let
        // their inner ScrollView take over.
        // History panel: takes priority over Settings (the user opens history
        // from the same opened-panel header strip; they aren't both visible).
        if showHistory {
            let h = min(max(historyPanelContentHeight, notchOpenedCompactMinHeight), notchOpenedMaxHeight)
            return CGSize(width: notchOpenedWidth, height: h)
        }
        if showSettings {
            let h = min(max(settingsContentHeight, notchOpenedCompactMinHeight), notchOpenedMaxHeight)
            return CGSize(width: notchOpenedWidth, height: h)
        }
        // Onboarding panels: drive the silhouette off the panel's measured
        // intrinsic height so the cards' natural size dictates the frame.
        // Otherwise we'd fall through to the compactMin floor (composer is
        // not mounted, so the measured-composer path can't fire), the cards
        // would overflow, and the tray drawer below would visually clip
        // them when notices push it open.
        if isOnboarding {
            let h = max(onboardingContentHeight, notchOpenedCompactMinHeight)
            return CGSize(width: notchOpenedWidth, height: h)
        }
        // No turns yet: panel hugs the composer card so the empty state
        // doesn't show wasted whitespace between the notch strip and the
        // input box. `openedContentVerticalChrome` already accounts for
        // top safe inset + bottom padding; the inner `spacing(8)` between
        // history and composer is irrelevant when history is absent.
        guard isAgentLoopActive else {
            let desired = deviceNotchRect.height + composerContentHeight + 16
            let clamped = max(desired, notchOpenedCompactMinHeight)
            return CGSize(width: notchOpenedWidth, height: clamped)
        }
        let desired = openedContentVerticalChrome + historyContentHeight + composerContentHeight
        let clamped = min(max(desired, notchOpenedCompactMinHeight), notchOpenedMaxHeight)
        return CGSize(width: notchOpenedWidth, height: clamped)
    }

    /// True once the conversation has at least one turn. Drives the panel
    /// height switch (compact → expanded) so the history scroll has room to
    /// render. Cleared by `AgentService.resetSession()` (the "+" header
    /// button) or implicitly when no turn has been submitted yet.
    public var isAgentLoopActive: Bool {
        !agentService.turns.isEmpty
    }
    public let inset: CGFloat
    public let animation: Animation = .smooth(duration: 0.38, extraBounce: 0)

    // MARK: - Dependencies (read-only from view)

    public let senseStore: SenseStore
    public let agentService: AgentService
    public let sessionService: SessionService
    public let providerService: ProviderService
    public let configService: ConfigService
    public let permissionsService: PermissionsService
    public let visualCapturePolicyStore: VisualCapturePolicyStore

    /// History popup visibility — driven by the header history button.
    public var showHistory: Bool = false

    /// Composer input state. Owned here (not by `ComposerCard`) so the
    /// rich text + chips survive notch close/reopen cycles — the panel
    /// view is dropped from the tree when the notch collapses, which
    /// would otherwise reset every `@State` in the composer.
    let composerInputModel: ChipInputModel = ChipInputModel()

    // Combine cancellables for the event-bridge subscriptions registered in
    // NotchViewModel+Events.swift.
    var cancellables: Set<AnyCancellable> = []

    /// Used to throttle haptic taps on popping transitions.
    var hapticSender = PassthroughSubject<Void, Never>()

    public init(
        senseStore: SenseStore,
        agentService: AgentService,
        sessionService: SessionService,
        providerService: ProviderService,
        configService: ConfigService,
        permissionsService: PermissionsService,
        visualCapturePolicyStore: VisualCapturePolicyStore,
        screenRect: CGRect,
        deviceNotchRect: CGRect
    ) {
        self.senseStore = senseStore
        self.agentService = agentService
        self.sessionService = sessionService
        self.providerService = providerService
        self.configService = configService
        self.permissionsService = permissionsService
        self.visualCapturePolicyStore = visualCapturePolicyStore
        self.screenRect = screenRect
        self.deviceNotchRect = deviceNotchRect
        // Per design: -4 if there is a real notch, 0 otherwise — expands the
        // hot rect slightly to absorb edge tracking error.
        self.inset = deviceNotchRect.height > 0 ? -4 : 0
        installBuiltinTraySources()
    }

    /// Wire the built-in tray sources. Each closure captures `self` weakly
    /// so the viewmodel can be torn down without the closures keeping it
    /// alive through the registered array. Order here is also display
    /// order in the drawer: action-bearing system notices first, then the
    /// agent's live status row last (it disappears the moment no item is
    /// in_progress, so it shouldn't push more important rows down when
    /// it's present).
    private func installBuiltinTraySources() {
        registerTraySource { [weak self] in
            guard let self else { return [] }
            return self.systemNoticeItems()
        }
        registerTraySource { [weak self] in
            guard let self else { return [] }
            return self.todoProgressItems()
        }
    }

    /// Action-required system rows (permissions / provider / corrupted
    /// config). Each is dismissable; `dismissTrayItem(id:)` records the
    /// id so subsequent renders skip it. The strings/ids match
    /// `BuiltinTrayItemID.*` so external callers (and tests) can target
    /// the exact row without cracking through internal lookup.
    private func systemNoticeItems() -> [TrayItem] {
        var out: [TrayItem] = []
        if !permissionsService.allGranted {
            out.append(TrayItem(
                id: BuiltinTrayItemID.missingPermission,
                icon: "exclamationmark.shield.fill",
                tint: .orange,
                message: missingPermissionMessage,
                trailing: .action("Open Settings"),
                onTap: { [weak self] in self?.showSettings = true }
            ))
        }
        if !providerService.hasReadyProvider {
            out.append(TrayItem(
                id: BuiltinTrayItemID.missingProvider,
                icon: "questionmark.circle.fill",
                tint: .yellow,
                message: "No model configured",
                trailing: .action("Open Settings"),
                onTap: { [weak self] in self?.showSettings = true }
            ))
        }
        if configService.recoveredFromCorruption {
            out.append(TrayItem(
                id: BuiltinTrayItemID.configCorruption,
                icon: "exclamationmark.triangle.fill",
                tint: .yellow,
                message: "Settings file was corrupt and has been reset.",
                trailing: nil,
                onTap: nil
            ))
        }
        return out
    }

    /// s03 TodoWrite live row. Surfaces only when the plan has an active
    /// in_progress step — empty / all-pending / all-completed plans don't
    /// produce a current step and would render an ambiguous row. Marked
    /// `dismissable: false` so the user can't accidentally hide live
    /// agent state via the dismiss path.
    private func todoProgressItems() -> [TrayItem] {
        let todos = agentService.todos
        guard let inProgress = todos.first(where: { $0.status == .inProgress }) else {
            return []
        }
        let done = todos.filter({ $0.status == .completed }).count
        return [TrayItem(
            id: BuiltinTrayItemID.todoProgress,
            icon: "checklist",
            tint: .white.opacity(0.85),
            message: inProgress.text,
            trailing: .badge("\(done)/\(todos.count)"),
            dismissable: false,
            onTap: nil
        )]
    }

    // MARK: - Derived geometry (pure functions)
    //
    // `Notch geometry helpers` are pure and tested independently; see
    // NotchGeometryTests.

    public var notchOpenedRect: CGRect {
        Self.makeNotchOpenedRect(screenRect: screenRect, panel: notchOpenedSize)
    }

    public var headlineOpenedRect: CGRect {
        Self.makeHeadlineOpenedRect(
            screenRect: screenRect,
            panel: notchOpenedSize,
            deviceNotchHeight: deviceNotchRect.height
        )
    }

    public var closedBarRect: CGRect {
        Self.makeClosedBarRect(deviceNotchRect: deviceNotchRect)
    }

    /// Mouse hot zone for closed/popping interactions. From the user's
    /// point of view the entire visible silhouette (icon + physical notch +
    /// emoji) reads as one "fat notch", so any hover/click landing on the
    /// satellite squares should drive popping/opening just like a hit on
    /// the physical cutout. `inset` matches the device-notch slack so edge
    /// tracking stays forgiving.
    public var closedHotRect: CGRect {
        closedBarRect.insetBy(dx: inset, dy: inset)
    }

    /// Screen-space rect of the currently-visible notch silhouette. Drives
    /// `NSWindow.ignoresMouseEvents` in `NotchWindowController` so clicks
    /// outside this rect pass through to the underlying app at the OS level
    /// — `NSHostingView`'s hit-testing returns self for any point in its
    /// bounds even where no SwiftUI view paints, so view-level filtering
    /// (NotchDrop-style or `hitTest`-override style) cannot achieve real
    /// click-through on macOS.
    public var visibleHotRect: CGRect {
        // `NotchShape` renders the silhouette `2 * shoulderRadius` wider than
        // the logical panel/bar rect (the shoulders extend horizontally past
        // `mainMinX/mainMaxX`). The hit rect must match the rendered bounding
        // box, otherwise clicks landing on the visible shoulder pixels fall
        // outside `ignoresMouseEvents` and pass through to the app below.
        // Keep these in sync with `NotchShape.shoulderRadius`.
        switch status {
        case .opened:
            return Self.makeOpenedVisibleRect(openedTotalRect: notchOpenedTotalRect)
        case .closed, .popping:
            return Self.makeClosedVisibleRect(closedBarRect: closedBarRect)
        }
    }

    public nonisolated static func makeNotchOpenedRect(screenRect: CGRect, panel: CGSize) -> CGRect {
        CGRect(
            x: screenRect.midX - panel.width / 2,
            y: screenRect.maxY - panel.height,
            width: panel.width,
            height: panel.height
        )
    }

    public nonisolated static func makeHeadlineOpenedRect(
        screenRect: CGRect,
        panel: CGSize,
        deviceNotchHeight: CGFloat
    ) -> CGRect {
        CGRect(
            x: screenRect.midX - panel.width / 2,
            y: screenRect.maxY - deviceNotchHeight,
            width: panel.width,
            height: deviceNotchHeight
        )
    }

    /// Tray drawer height policy. Pure: depends only on notice count, the
    /// expanded flag, the measured content height, and the tray's collapsed/max
    /// constants — no service reads. Used by `notchTraySize` and exercised
    /// directly in tests.
    ///   • Zero notices → height 0 (drawer absent).
    ///   • Single notice OR expanded → measured content, clamped into
    ///     [collapsedHeight, maxHeight].
    ///   • Multi-notice + collapsed → fixed collapsedHeight (one row's worth);
    ///     the additional rows are still in the layout and clipped by the
    ///     parent's frame for a clean drawer-extending animation.
    public nonisolated static func makeTraySize(
        width: CGFloat,
        itemCount: Int,
        expanded: Bool,
        measuredContentHeight: CGFloat,
        collapsedHeight: CGFloat,
        maxHeight: CGFloat
    ) -> CGSize {
        guard itemCount > 0 else {
            return CGSize(width: width, height: 0)
        }
        if itemCount == 1 || expanded {
            let h = min(max(measuredContentHeight, collapsedHeight), maxHeight)
            return CGSize(width: width, height: h)
        }
        return CGSize(width: width, height: collapsedHeight)
    }

    /// Combined main+tray rect, top-aligned to `screenRect.maxY` and centered
    /// horizontally. Drives the window strip height and the click-through hot
    /// rect when opened.
    public nonisolated static func makeOpenedTotalRect(
        screenRect: CGRect,
        totalSize: CGSize
    ) -> CGRect {
        CGRect(
            x: screenRect.midX - totalSize.width / 2,
            y: screenRect.maxY - totalSize.height,
            width: totalSize.width,
            height: totalSize.height
        )
    }

    /// Shoulder radius the painted silhouette extends past the logical rect on
    /// each side. The hit rect must match the rendered bounding box, otherwise
    /// clicks landing on visible shoulder pixels fall outside the window's
    /// non-mouse-transparent area and pass through to the app below. The
    /// values must stay in sync with `NotchShape.shoulderRadius` (opened) and
    /// the closed-bar shoulder used by the closed-state silhouette.
    public nonisolated static let openedShoulderRadius: CGFloat = 18
    public nonisolated static let closedShoulderRadius: CGFloat = 6

    public nonisolated static func makeOpenedVisibleRect(openedTotalRect: CGRect) -> CGRect {
        openedTotalRect.insetBy(dx: -openedShoulderRadius, dy: 0)
    }

    public nonisolated static func makeClosedVisibleRect(closedBarRect: CGRect) -> CGRect {
        closedBarRect.insetBy(dx: -closedShoulderRadius, dy: 0)
    }

    public nonisolated static func makeClosedBarRect(deviceNotchRect: CGRect) -> CGRect {
        CGRect(
            x: deviceNotchRect.minX - deviceNotchRect.height,
            y: deviceNotchRect.minY,
            width: deviceNotchRect.width + deviceNotchRect.height * 2,
            height: deviceNotchRect.height
        )
    }

    // MARK: - State mutators

    public func notchOpen(_ reason: OpenReason) {
        openReason = reason
        status = .opened
        NSApp.activate(ignoringOtherApps: true)
        // Force a fresh AX read of the prior frontmost app so the user sees
        // their just-made selection / typed-input chip immediately. Live AX
        // notifications are unreliable in terminals (Ghostty), Electron, and
        // other custom-rendered apps — they only fire after subsequent focus
        // shifts, which is why the chip used to "appear after clicking the
        // input". Snapshot-on-open removes that dependency.
        senseStore.refreshGeneralProbe()
        broadcastStatus()
    }

    public func notchClose() {
        status = .closed
        showSettings = false
        showHistory = false
        broadcastStatus()
    }

    public func notchPop() {
        guard status == .closed else { return }
        status = .popping
        broadcastStatus()
    }

    // MARK: - Tray actions

    /// Hide a tray row for the rest of the session. Routes the
    /// corruption-banner case through ConfigService so its server-side
    /// acknowledgement also fires. Calling this with an id that's
    /// non-dismissable (e.g. live `agent.todoProgress`) is a no-op — the
    /// item's source is the lifecycle authority and re-emits the row on
    /// the next render regardless of the dismissed set; we still record
    /// the id so the contract is uniform, but `trayItems` deliberately
    /// does NOT filter non-dismissable rows by id (defensive: future
    /// callers can't accidentally hide live state by reusing this path).
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
        if id == BuiltinTrayItemID.configCorruption {
            configService.dismissCorruptionNotice()
        }
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

    /// Cancel all subscriptions; called by the controller during destroy.
    public func destroy() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }
}
