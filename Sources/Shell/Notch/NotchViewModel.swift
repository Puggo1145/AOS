import Foundation
import AppKit
import SwiftUI
import Combine
import OSSenseKit

// MARK: - System tray notice model
//
// Surfaces in the drawer that pokes out from below the main panel. Each kind
// is derived from a service signal (permission missing, no provider, config
// reset). Dismissing is session-scoped — the user can hide a notice for the
// remainder of the run; the underlying condition still drives onboarding /
// inline-disabled-input behaviour.

// `TrayItem` and `TraySource` live in `Notch/Chrome/TrayItem.swift`.
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

    public enum DetachMorphPhase: Sendable, Equatable {
        case idle
        case source
        case target
    }

    public struct PanelCornerRadii: Sendable, Equatable {
        public let topLeading: CGFloat
        public let topTrailing: CGFloat
        public let bottomLeading: CGFloat
        public let bottomTrailing: CGFloat

        public init(
            topLeading: CGFloat,
            topTrailing: CGFloat,
            bottomLeading: CGFloat,
            bottomTrailing: CGFloat
        ) {
            self.topLeading = topLeading
            self.topTrailing = topTrailing
            self.bottomLeading = bottomLeading
            self.bottomTrailing = bottomTrailing
        }

        public init(all radius: CGFloat) {
            self.init(
                topLeading: radius,
                topTrailing: radius,
                bottomLeading: radius,
                bottomTrailing: radius
            )
        }
    }

    public struct DetachMorphPresentation: Sendable, Equatable {
        public let shoulderRadius: CGFloat
        public let contentTopPadding: CGFloat
        public let silhouetteSize: CGSize
        public let shapeCornerRadii: PanelCornerRadii
        public let contentClipCornerRadii: PanelCornerRadii
        public let chromeOverlayOpacity: CGFloat

        public var bottomCornerRadius: CGFloat { shapeCornerRadii.bottomLeading }
        public var topCornerRadius: CGFloat { shapeCornerRadii.topLeading }
        public var contentClipTopRadius: CGFloat { contentClipCornerRadii.topLeading }
        public var contentClipBottomRadius: CGFloat { contentClipCornerRadii.bottomLeading }
    }

    // MARK: - Stored state

    public private(set) var status: Status = .closed
    public var openReason: OpenReason = .unknown
    public var screenRect: CGRect
    public var deviceNotchRect: CGRect
    public var placement: NotchPlacement = .attachedTop
    public var inputFocused: Bool = false
    private var detachDragOffset: CGPoint?
    private var detachTransitionTask: Task<Void, Never>?
    public var isDetachDragging: Bool { detachDragOffset != nil }
    public private(set) var detachMorphPhase: DetachMorphPhase = .idle
    public var isDetachTransitionActive: Bool { detachMorphPhase != .idle }
    public private(set) var isEdgeRevealTransitionActive: Bool = false
    /// Settings panel overlay. Reachable from the gear button in
    /// OpenedPanelView; reset to false on close.
    public var showSettings: Bool = false {
        didSet {
            if showSettings, !oldValue {
                settingsMeasurementPending = true
                settingsPendingPanelHeight = openedBasePanelHeight
            }
            openedSurfaceStateDidChange()
        }
    }

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
    public var onboardingContentHeight: CGFloat = 0 {
        didSet { openedSurfaceStateDidChange() }
    }

    /// Measured natural height of SettingsPanelView. Same content-driven
    /// pattern as onboarding: PreferenceKey reports the intrinsic height,
    /// `notchOpenedSize` clamps it into [compactMin, max]. Adding/removing
    /// rows in Settings no longer needs a hand-tuned constant.
    public var settingsContentHeight: CGFloat = 0 {
        didSet { openedSurfaceStateDidChange() }
    }
    private var settingsMeasurementPending: Bool = false
    private var settingsPendingPanelHeight: CGFloat?

    /// Measured natural height of SessionHistoryPanelView. Same content-driven
    /// pattern as Settings: PreferenceKey reports the intrinsic height,
    /// `notchOpenedSize` clamps it into [compactMin, max]; the inner
    /// ScrollView takes over once the list exceeds the ceiling.
    public var historyPanelContentHeight: CGFloat = 0 {
        didSet { openedSurfaceStateDidChange() }
    }
    private var historyMeasurementPending: Bool = false
    private var historyPendingPanelHeight: CGFloat?

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
    public var historyContentHeight: CGFloat = 0 {
        didSet { openedSurfaceStateDidChange() }
    }
    public var composerContentHeight: CGFloat = 0 {
        didSet { openedSurfaceStateDidChange() }
    }

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
    public var dismissedItemIds: Set<String> = [] {
        didSet { openedSurfaceStateDidChange() }
    }
    public var trayExpanded: Bool = false {
        didSet { openedSurfaceStateDidChange() }
    }
    public var trayContentHeight: CGFloat = 0 {
        didSet { openedSurfaceStateDidChange() }
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

    /// Active drawer rows. Composes every registered source, then drops
    /// rows whose ids the user has dismissed. Source registration order
    /// is the display order — built-in system notices (permission /
    /// provider / config) are registered first in `init`, so they always
    /// render above later additions like the agent's todo-progress row.
    ///
    /// Slash-command palette short-circuits this composition: while the
    /// palette is active the drawer is the command palette's surface,
    /// not a notice list. Mixing system notices with command suggestions
    /// would dilute both — the user is mid-keystroke selecting a command,
    /// not triaging notices. Notices flip back the instant the palette
    /// gate fails (e.g. user types space, escapes, or executes).
    public var trayItems: [TrayItem] {
        if commandPalette.isActive {
            return commandPaletteItems()
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
        commandPalette.isActive || trayExpanded
    }

    /// True iff the drawer is currently rendering slash-command rows
    /// (vs. ordinary notices). Used by SystemTrayView to drop the
    /// dismiss `×` and the collapsed/expanded chevron — neither has
    /// meaning during command selection.
    public var isCommandPaletteMode: Bool {
        commandPalette.isActive
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
            expanded: effectiveTrayExpanded,
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
    var missingPermissionMessage: String {
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
        return !permissionsService.onboardingPermissionsComplete || !providerService.hasReadyProvider
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
            let h = measuredOverlayPanelHeight(
                historyPanelContentHeight,
                measurementPending: historyMeasurementPending,
                pendingPanelHeight: historyPendingPanelHeight
            )
            return CGSize(width: notchOpenedWidth, height: h)
        }
        if showSettings {
            let h = measuredOverlayPanelHeight(
                settingsContentHeight,
                measurementPending: settingsMeasurementPending,
                pendingPanelHeight: settingsPendingPanelHeight
            )
            return CGSize(width: notchOpenedWidth, height: h)
        }
        return CGSize(width: notchOpenedWidth, height: openedBasePanelHeight)
    }

    private var openedBasePanelHeight: CGFloat {
        // Onboarding panels: drive the silhouette off the panel's measured
        // intrinsic height so the cards' natural size dictates the frame.
        // Otherwise we'd fall through to the compactMin floor (composer is
        // not mounted, so the measured-composer path can't fire), the cards
        // would overflow, and the tray drawer below would visually clip
        // them when notices push it open.
        if isOnboarding {
            return max(onboardingContentHeight, notchOpenedCompactMinHeight)
        }
        // No turns yet: panel hugs the composer card so the empty state
        // doesn't show wasted whitespace between the notch strip and the
        // input box. `openedContentVerticalChrome` already accounts for
        // top safe inset + bottom padding; the inner `spacing(8)` between
        // history and composer is irrelevant when history is absent.
        guard isAgentLoopActive else {
            let desired = deviceNotchRect.height + composerContentHeight + 16
            return max(desired, notchOpenedCompactMinHeight)
        }
        let desired = openedContentVerticalChrome + historyContentHeight + composerContentHeight
        return min(max(desired, notchOpenedCompactMinHeight), notchOpenedMaxHeight)
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
    public let mcpService: McpService
    public let permissionsService: PermissionsService
    public let visualCapturePolicyStore: VisualCapturePolicyStore
    public let permissionApprovalService: PermissionApprovalService?

    /// History popup visibility — driven by the header history button.
    public var showHistory: Bool = false {
        didSet {
            if showHistory, !oldValue {
                historyMeasurementPending = true
                historyPendingPanelHeight = openedBasePanelHeight
            }
            openedSurfaceStateDidChange()
        }
    }

    /// Composer input state. Owned here (not by `ComposerCard`) so the
    /// rich text + chips survive notch close/reopen cycles — the panel
    /// view is dropped from the tree when the notch collapses, which
    /// would otherwise reset every `@State` in the composer.
    let composerInputModel: ChipInputModel = ChipInputModel()

    /// Slash-command palette state. Owned at the viewmodel level so the
    /// notch tray (rendered above the composer in the view tree) can
    /// project palette matches into its drawer rows. The composer
    /// updates this on every text change; the tray reads it via the
    /// registered tray source below.
    public let commandPalette = CommandPaletteState()

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
        mcpService: McpService,
        permissionsService: PermissionsService,
        visualCapturePolicyStore: VisualCapturePolicyStore,
        permissionApprovalService: PermissionApprovalService? = nil,
        screenRect: CGRect,
        deviceNotchRect: CGRect
    ) {
        self.senseStore = senseStore
        self.agentService = agentService
        self.sessionService = sessionService
        self.providerService = providerService
        self.configService = configService
        self.mcpService = mcpService
        self.permissionsService = permissionsService
        self.visualCapturePolicyStore = visualCapturePolicyStore
        self.permissionApprovalService = permissionApprovalService
        self.screenRect = screenRect
        self.deviceNotchRect = deviceNotchRect
        // Per design: -4 if there is a real notch, 0 otherwise — expands the
        // hot rect slightly to absorb edge tracking error.
        self.inset = deviceNotchRect.height > 0 ? -4 : 0
        installBuiltinTraySources()
    }

    // MARK: - Derived geometry (pure functions)
    //
    // `Notch geometry helpers` are pure and tested independently; see
    // NotchGeometryTests.

    public var notchOpenedRect: CGRect {
        NotchGeometryModel.makeNotchOpenedRect(screenRect: screenRect, panel: notchOpenedSize)
    }

    public var headlineOpenedRect: CGRect {
        NotchGeometryModel.makeHeadlineOpenedRect(
            screenRect: screenRect,
            panel: notchOpenedSize,
            deviceNotchHeight: deviceNotchRect.height
        )
    }

    public var closedBarRect: CGRect {
        NotchGeometryModel.makeClosedBarRect(deviceNotchRect: deviceNotchRect)
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
    /// paint-aligned hit math such as hover affordances. Mouse click-through
    /// uses `mouseActiveRect`; opened-state content height can lag SwiftUI
    /// measurement by a frame, and using this rect for OS-level click-through
    /// can drop legitimate clicks before SwiftUI receives them.
    public var visibleHotRect: CGRect {
        // `NotchShape` renders the silhouette `2 * shoulderRadius` wider than
        // the logical panel/bar rect (the shoulders extend horizontally past
        // `mainMinX/mainMaxX`). The hit rect must match the rendered bounding
        // box, otherwise clicks landing on the visible shoulder pixels fall
        // outside the paint-aligned interaction affordance.
        // Keep these in sync with `NotchShape.shoulderRadius`.
        switch status {
        case .opened:
            return NotchGeometryModel.makeOpenedVisibleRect(openedTotalRect: notchOpenedTotalRect)
        case .closed, .popping:
            return NotchGeometryModel.makeClosedVisibleRect(closedBarRect: closedBarRect)
        }
    }

    /// Screen-space rect that keeps the overlay mouse-active. In opened
    /// state this deliberately uses the maximum panel+tray budget instead
    /// of the currently measured silhouette height: settings and history
    /// pages report height asynchronously, and a stale smaller measurement
    /// must not flip `ignoresMouseEvents` before an in-panel click arrives.
    public var mouseActiveRect: CGRect {
        if !isAttachedTop {
            return NotchPlacementGeometry.mouseActiveRect(for: currentPlacement)
        }

        switch status {
        case .opened:
            let measurementPending = (showSettings && settingsMeasurementPending)
                || (showHistory && historyMeasurementPending)
            return NotchGeometryModel.makeOpenedMouseActiveRect(
                visibleRect: visibleHotRect,
                screenRect: screenRect,
                width: notchOpenedWidth,
                maxHeight: notchOpenedMaxHeight + notchTrayMaxHeight,
                measurementPending: measurementPending
            )
        case .closed, .popping:
            return visibleHotRect
        }
    }

    public var detachedCornerRadius: CGFloat { 18 }
    public var detachedTopPadding: CGFloat { 10 }
    public var detachMorphDuration: Duration { .milliseconds(320) }

    public var detachedTotalSize: CGSize {
        CGSize(
            width: notchOpenedTotalSize.width,
            height: notchOpenedTotalSize.height + detachedTopPadding
        )
    }

    public var isAttachedTop: Bool {
        if case .attachedTop = placement { return true }
        return false
    }

    public var currentPlacement: NotchPlacement {
        NotchPlacementGeometry.resizedFloatingPlacement(
            placement,
            screenRect: screenRect,
            targetSize: detachedTotalSize
        )
    }

    private func measuredOverlayPanelHeight(
        _ measuredHeight: CGFloat,
        measurementPending: Bool,
        pendingPanelHeight: CGFloat?
    ) -> CGFloat {
        if measuredHeight > 0 {
            return min(max(measuredHeight, notchOpenedCompactMinHeight), notchOpenedMaxHeight)
        }
        if measurementPending, let pendingPanelHeight {
            return min(max(pendingPanelHeight, notchOpenedCompactMinHeight), notchOpenedMaxHeight)
        }
        return min(max(measuredHeight, notchOpenedCompactMinHeight), notchOpenedMaxHeight)
    }

    public nonisolated static func makeDetachMorphPresentation(
        phase: DetachMorphPhase,
        placement: NotchPlacement,
        screenRect: CGRect,
        finalSize: CGSize,
        sourceHeight: CGFloat,
        sourceBottomCornerRadius: CGFloat,
        targetCornerRadius: CGFloat,
        targetTopPadding: CGFloat
    ) -> DetachMorphPresentation {
        precondition(screenRect.width > 0 && screenRect.height > 0, "Screen rect must be positive")
        precondition(finalSize.width > 0 && finalSize.height > 0, "Detach size must be positive")
        precondition(sourceHeight > 0, "Detach source height must be positive")
        precondition(targetTopPadding >= 0, "Detach top padding cannot be negative")

        switch phase {
        case .source:
            let shoulderRadius = NotchGeometryModel.openedShoulderRadius
            return DetachMorphPresentation(
                shoulderRadius: shoulderRadius,
                contentTopPadding: 0,
                silhouetteSize: CGSize(
                    width: finalSize.width + 2 * shoulderRadius,
                    height: sourceHeight
                ),
                shapeCornerRadii: PanelCornerRadii(
                    topLeading: 0,
                    topTrailing: 0,
                    bottomLeading: sourceBottomCornerRadius,
                    bottomTrailing: sourceBottomCornerRadius
                ),
                contentClipCornerRadii: PanelCornerRadii(
                    topLeading: 0,
                    topTrailing: 0,
                    bottomLeading: sourceBottomCornerRadius,
                    bottomTrailing: sourceBottomCornerRadius
                ),
                chromeOverlayOpacity: 0
            )
        case .target, .idle:
            let cornerRadii = edgeAdjustedCornerRadii(
                PanelCornerRadii(all: targetCornerRadius),
                placement: placement,
                screenRect: screenRect
            )
            return DetachMorphPresentation(
                shoulderRadius: 0,
                contentTopPadding: targetTopPadding,
                silhouetteSize: finalSize,
                shapeCornerRadii: cornerRadii,
                contentClipCornerRadii: cornerRadii,
                chromeOverlayOpacity: 0
            )
        }
    }

    private nonisolated static func edgeAdjustedCornerRadii(
        _ radii: PanelCornerRadii,
        placement: NotchPlacement,
        screenRect: CGRect
    ) -> PanelCornerRadii {
        let edge: NotchEdge?
        switch placement {
        case let .edgeDock(dockedEdge, _, _, _, _):
            edge = dockedEdge
        case let .detached(frame):
            edge = NotchPlacementGeometry.touchingDockEdge(
                screenRect: screenRect,
                frame: frame
            )
        case .attachedTop:
            edge = nil
        }

        guard let edge else {
            return radii
        }

        switch edge {
        case .left:
            return PanelCornerRadii(
                topLeading: 0,
                topTrailing: radii.topTrailing,
                bottomLeading: 0,
                bottomTrailing: radii.bottomTrailing
            )
        case .right:
            return PanelCornerRadii(
                topLeading: radii.topLeading,
                topTrailing: 0,
                bottomLeading: radii.bottomLeading,
                bottomTrailing: 0
            )
        case .bottom:
            return PanelCornerRadii(
                topLeading: radii.topLeading,
                topTrailing: radii.topTrailing,
                bottomLeading: 0,
                bottomTrailing: 0
            )
        case .top:
            return radii
        }
    }

    func markSettingsMeasured(height: CGFloat) {
        if height > 0 {
            settingsMeasurementPending = false
            settingsPendingPanelHeight = nil
        }
        settingsContentHeight = height
    }

    func markHistoryMeasured(height: CGFloat) {
        if height > 0 {
            historyMeasurementPending = false
            historyPendingPanelHeight = nil
        }
        historyPanelContentHeight = height
    }

    public nonisolated static func makeNotchOpenedRect(screenRect: CGRect, panel: CGSize) -> CGRect {
        NotchGeometryModel.makeNotchOpenedRect(screenRect: screenRect, panel: panel)
    }

    public nonisolated static func makeHeadlineOpenedRect(
        screenRect: CGRect,
        panel: CGSize,
        deviceNotchHeight: CGFloat
    ) -> CGRect {
        NotchGeometryModel.makeHeadlineOpenedRect(
            screenRect: screenRect,
            panel: panel,
            deviceNotchHeight: deviceNotchHeight
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
        NotchGeometryModel.makeTraySize(
            width: width,
            itemCount: itemCount,
            expanded: expanded,
            measuredContentHeight: measuredContentHeight,
            collapsedHeight: collapsedHeight,
            maxHeight: maxHeight
        )
    }

    /// Combined main+tray rect, top-aligned to `screenRect.maxY` and centered
    /// horizontally. Drives the window strip height and the click-through hot
    /// rect when opened.
    public nonisolated static func makeOpenedTotalRect(
        screenRect: CGRect,
        totalSize: CGSize
    ) -> CGRect {
        NotchGeometryModel.makeOpenedTotalRect(screenRect: screenRect, totalSize: totalSize)
    }

    /// Shoulder radius the painted silhouette extends past the logical rect on
    /// each side. The hit rect must match the rendered bounding box, otherwise
    /// clicks landing on visible shoulder pixels fall outside the window's
    /// non-mouse-transparent area and pass through to the app below. The
    /// values must stay in sync with `NotchShape.shoulderRadius` (opened) and
    /// the closed-bar shoulder used by the closed-state silhouette.
    public nonisolated static let openedShoulderRadius = NotchGeometryModel.openedShoulderRadius
    public nonisolated static let closedShoulderRadius = NotchGeometryModel.closedShoulderRadius

    public nonisolated static func makeOpenedVisibleRect(openedTotalRect: CGRect) -> CGRect {
        NotchGeometryModel.makeOpenedVisibleRect(openedTotalRect: openedTotalRect)
    }

    public nonisolated static func makeOpenedMouseActiveRect(
        visibleRect: CGRect,
        screenRect: CGRect,
        width: CGFloat,
        maxHeight: CGFloat,
        measurementPending: Bool
    ) -> CGRect {
        NotchGeometryModel.makeOpenedMouseActiveRect(
            visibleRect: visibleRect,
            screenRect: screenRect,
            width: width,
            maxHeight: maxHeight,
            measurementPending: measurementPending
        )
    }

    public nonisolated static func makeClosedVisibleRect(closedBarRect: CGRect) -> CGRect {
        NotchGeometryModel.makeClosedVisibleRect(closedBarRect: closedBarRect)
    }

    public nonisolated static func makeClosedBarRect(deviceNotchRect: CGRect) -> CGRect {
        NotchGeometryModel.makeClosedBarRect(deviceNotchRect: deviceNotchRect)
    }

    // MARK: - State mutators

    public func notchOpen(_ reason: OpenReason) {
        openReason = reason
        status = .opened
        broadcastStatus()
        // Force a fresh AX read of the prior frontmost app so the user sees
        // their just-made selection / typed-input chip promptly. Schedule it
        // after the opened-state broadcast because AX reads for large text
        // areas can block the main actor; the first opened frame is more
        // important than having the chip row fully refreshed before paint.
        senseStore.refreshGeneralProbeDeferred()
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

    public func setPlacement(_ placement: NotchPlacement) {
        guard self.placement != placement else { return }
        self.placement = placement
        broadcastPlacement()
    }

    /// Detached placement is position state only. Opened-surface state
    /// changes invalidate the derived current placement so AppKit can resize
    /// the hosting window before SwiftUI paints the new height.
    private func openedSurfaceStateDidChange() {
        guard !isAttachedTop else { return }
        broadcastPlacement()
    }

    public func revealEdgeDock() {
        guard case let .edgeDock(edge, hiddenFrame, revealFrame, triggerFrame, false) = currentPlacement else { return }
        setPlacement(.edgeDock(
            edge: edge,
            hiddenFrame: hiddenFrame,
            revealFrame: revealFrame,
            triggerFrame: triggerFrame,
            revealed: true
        ))
    }

    public func collapseEdgeDock() {
        guard case let .edgeDock(edge, hiddenFrame, revealFrame, triggerFrame, true) = currentPlacement else { return }
        setPlacement(.edgeDock(
            edge: edge,
            hiddenFrame: hiddenFrame,
            revealFrame: revealFrame,
            triggerFrame: triggerFrame,
            revealed: false
        ))
    }

    public func startDetachDrag(pointer: CGPoint) {
        guard detachDragOffset == nil else {
            updateDetachDrag(pointer: pointer)
            return
        }

        notchOpen(.click)
        if isAttachedTop {
            startDetachShapeTransition()
        }
        let startFrame = NotchPlacementGeometry.currentPanelFrame(
            placement: currentPlacement,
            attachedFrame: notchOpenedTotalRect
        )
        detachDragOffset = CGPoint(
            x: pointer.x - startFrame.minX,
            y: pointer.y - startFrame.minY
        )
        updateDetachDrag(pointer: pointer)
    }

    public func updateDetachDrag(pointer: CGPoint) {
        guard let offset = detachDragOffset else {
            preconditionFailure("Detach drag offset missing")
        }
        let frame = NotchPlacementGeometry.detachedFrame(
            screenRect: screenRect,
            panelSize: detachedTotalSize,
            pointer: pointer,
            dragOffset: offset
        )
        setPlacement(.detached(frame))
    }

    public func finishDetachDrag(pointer _: CGPoint) {
        guard detachDragOffset != nil else {
            preconditionFailure("Cannot end a detach drag that has not begun")
        }
        guard case let .detached(releasedFrame) = currentPlacement else {
            preconditionFailure("Cannot finish detach drag without a current detached frame")
        }
        detachDragOffset = nil
        setPlacement(NotchPlacementGeometry.placementOnRelease(
            screenRect: screenRect,
            deviceNotchRect: deviceNotchRect,
            panelFrame: releasedFrame
        ))
    }

    private func startDetachShapeTransition() {
        detachTransitionTask?.cancel()
        detachMorphPhase = .source
        detachTransitionTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            detachMorphPhase = .target
            do {
                try await Task.sleep(for: detachMorphDuration)
            } catch {
                return
            }
            detachMorphPhase = .idle
        }
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
        detachTransitionTask?.cancel()
        detachTransitionTask = nil
        detachMorphPhase = .idle
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }
}
