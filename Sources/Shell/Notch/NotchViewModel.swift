import Foundation
import AppKit
import SwiftUI
import Combine
import OSSenseKit

// MARK: - System tray notice model
//
// Surfaces in the drawer that pokes out from below the main panel. Ownership
// of the drawer's state lives on `NotchTrayModel` (Chrome/NotchTrayModel.swift);
// the viewmodel exposes it as `tray` and installs the built-in sources
// (Notch/NotchViewModel+Tray.swift) since those read viewmodel services.

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

    // MARK: - Stored state

    public private(set) var status: Status = .closed
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
                measurements.beginSettingsMeasurement(fallback: openedBasePanelHeight)
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

    /// Vertical chrome around the dynamic content inside OpenedPanelView:
    /// top safe inset + spacing(8) between history and composer + bottom
    /// padding(16). Kept here so `notchOpenedSize` can clamp the panel's
    /// natural size without re-deriving the layout's paddings.
    public var openedContentVerticalChrome: CGFloat {
        deviceNotchRect.height + 8 + 16
    }

    // MARK: - Panel measurements
    //
    // Measured natural heights of the opened panel's swappable content
    // (onboarding / Settings / History / conversation + composer stacks).
    // Ownership lives on `NotchPanelMeasurements`; see
    // NotchPanelMeasurements.swift for the clamping + pending-measurement
    // rules.
    public let measurements: NotchPanelMeasurements

    // MARK: - System tray (drawer)
    //
    // The drawer pokes out from below the main panel when there are pending
    // notices (permission gaps, missing provider, config-corruption notice).
    // Ownership of the drawer's state (dismissals, expansion, measured
    // height, registered sources) lives on `NotchTrayModel`; see
    // Chrome/NotchTrayModel.swift for the composition + dismissal rules.
    public let tray: NotchTrayModel

    /// Tray rect — width matches the main panel.
    public var notchTraySize: CGSize {
        tray.traySize(width: notchOpenedWidth)
    }

    /// Combined bounding box of main panel + tray. Drives the window strip
    /// height and the click-through hot rect when opened.
    public var notchOpenedTotalSize: CGSize {
        let main = notchOpenedSize
        let traySize = notchTraySize
        return CGSize(width: main.width, height: main.height + traySize.height)
    }

    public var notchOpenedTotalRect: CGRect {
        NotchGeometryModel.makeOpenedTotalRect(screenRect: screenRect, totalSize: notchOpenedTotalSize)
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
            let h = measurements.historyHeight(
                compactMinHeight: notchOpenedCompactMinHeight,
                maxHeight: notchOpenedMaxHeight
            )
            return CGSize(width: notchOpenedWidth, height: h)
        }
        if showSettings {
            let h = measurements.settingsHeight(
                compactMinHeight: notchOpenedCompactMinHeight,
                maxHeight: notchOpenedMaxHeight
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
            return max(measurements.onboardingContentHeight, notchOpenedCompactMinHeight)
        }
        // No turns yet: panel hugs the composer card so the empty state
        // doesn't show wasted whitespace between the notch strip and the
        // input box. `openedContentVerticalChrome` already accounts for
        // top safe inset + bottom padding; the inner `spacing(8)` between
        // history and composer is irrelevant when history is absent.
        guard isAgentLoopActive else {
            let desired = deviceNotchRect.height + measurements.composerContentHeight + 16
            return max(desired, notchOpenedCompactMinHeight)
        }
        let desired = openedContentVerticalChrome + measurements.historyContentHeight + measurements.composerContentHeight
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
                measurements.beginHistoryMeasurement(fallback: openedBasePanelHeight)
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

    /// Last time the popping-entry haptic fired; see `fireHapticIfNeeded()`
    /// in NotchViewModel+Events.swift for the throttle rule (§7.4).
    var lastPoppingHapticAt: Date?

    // MARK: - Status / placement callbacks
    //
    // Replaces a NotificationCenter event bus that used to bridge status/
    // placement mutations to NotchWindowController. Direct typed callbacks:
    // one subscriber each (the controller), wired in
    // `NotchWindowController.bindClickThrough` and nil'd out in its
    // `destroy()`.

    /// Fired synchronously after every `status` mutation (open/close/pop).
    public var onStatusChanged: (@MainActor (Status) -> Void)?

    /// Fired synchronously after `placement` changes, or after an
    /// opened-surface state change that invalidates the derived current
    /// placement (see `openedSurfaceStateDidChange`).
    public var onPlacementChanged: (@MainActor () -> Void)?

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
        self.tray = NotchTrayModel(
            // `nil` means "compose the registered notice sources instead" —
            // see NotchTrayModel.trayItems.
            paletteItems: { nil },
            onDismiss: { _ in }
        )
        self.measurements = NotchPanelMeasurements()
        // Wire the closures that need `self` only after every stored
        // property has a value (two-phase init: `self` can't be captured
        // in a closure before that point).
        tray.configure(
            paletteItems: { [weak self] in
                guard let self, self.commandPalette.isActive else { return nil }
                return self.commandPaletteItems()
            },
            onDismiss: { [weak self] id in
                if id == BuiltinTrayItemID.configCorruption {
                    self?.configService.dismissCorruptionNotice()
                }
            }
        )
        tray.onStateChange = { [weak self] in self?.openedSurfaceStateDidChange() }
        measurements.onStateChange = { [weak self] in self?.openedSurfaceStateDidChange() }
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
            let measurementPending = (showSettings && measurements.settingsMeasurementPending)
                || (showHistory && measurements.historyMeasurementPending)
            return NotchGeometryModel.makeOpenedMouseActiveRect(
                visibleRect: visibleHotRect,
                screenRect: screenRect,
                width: notchOpenedWidth,
                maxHeight: notchOpenedMaxHeight + tray.notchTrayMaxHeight,
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

    // MARK: - State mutators

    public func notchOpen() {
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
        fireHapticIfNeeded()
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

        notchOpen()
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

    /// Cancel all subscriptions; called by the controller during destroy.
    public func destroy() {
        detachTransitionTask?.cancel()
        detachTransitionTask = nil
        detachMorphPhase = .idle
        onStatusChanged = nil
        onPlacementChanged = nil
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }
}
