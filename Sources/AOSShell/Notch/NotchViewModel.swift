import Foundation
import AppKit
import SwiftUI
import Combine
import AOSOSSenseKit

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
    /// loop is active. `compact` fits exactly: top safe inset + context chips
    /// + 1-line input + bottom padding (room for the gear). `max` is the
    /// hosting NSWindow's strip height — the silhouette never grows past it,
    /// instead the history ScrollView starts scrolling.
    public let notchOpenedWidth: CGFloat = 500
    public let notchOpenedCompactHeight: CGFloat = 170
    public let notchOpenedMaxHeight: CGFloat = 480
    /// Settings panel uses a fixed 240pt budget — provider/model/effort
    /// cards + quit button were laid out for this height and don't benefit
    /// from the conversation panel's larger max.
    public let notchOpenedSettingsHeight: CGFloat = 240

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

    public var notchOpenedSize: CGSize {
        // Settings always needs the full panel — provider/model/effort cards
        // plus the quit button don't fit in compact height.
        if showSettings {
            return CGSize(width: notchOpenedWidth, height: notchOpenedSettingsHeight)
        }
        guard isAgentLoopActive else {
            return CGSize(width: notchOpenedWidth, height: notchOpenedCompactHeight)
        }
        let desired = openedContentVerticalChrome + historyContentHeight + composerContentHeight
        let clamped = min(max(desired, notchOpenedCompactHeight), notchOpenedMaxHeight)
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
    public let animation: Animation = .interactiveSpring(
        duration: 0.5,
        extraBounce: 0.25,
        blendDuration: 0.125
    )

    // MARK: - Dependencies (read-only from view)

    public let senseStore: SenseStore
    public let agentService: AgentService
    public let providerService: ProviderService
    public let configService: ConfigService
    public let permissionsService: PermissionsService

    // Combine cancellables for the event-bridge subscriptions registered in
    // NotchViewModel+Events.swift.
    var cancellables: Set<AnyCancellable> = []

    /// Used to throttle haptic taps on popping transitions.
    var hapticSender = PassthroughSubject<Void, Never>()

    public init(
        senseStore: SenseStore,
        agentService: AgentService,
        providerService: ProviderService,
        configService: ConfigService,
        permissionsService: PermissionsService,
        screenRect: CGRect,
        deviceNotchRect: CGRect
    ) {
        self.senseStore = senseStore
        self.agentService = agentService
        self.providerService = providerService
        self.configService = configService
        self.permissionsService = permissionsService
        self.screenRect = screenRect
        self.deviceNotchRect = deviceNotchRect
        // Per design: -4 if there is a real notch, 0 otherwise — expands the
        // hot rect slightly to absorb edge tracking error.
        self.inset = deviceNotchRect.height > 0 ? -4 : 0
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
        switch status {
        case .opened: return notchOpenedRect
        case .closed, .popping: return closedBarRect
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
        broadcastStatus()
    }

    public func notchClose() {
        status = .closed
        showSettings = false
        broadcastStatus()
    }

    public func notchPop() {
        guard status == .closed else { return }
        status = .popping
        broadcastStatus()
    }

    /// Cancel all subscriptions; called by the controller during destroy.
    public func destroy() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }
}
