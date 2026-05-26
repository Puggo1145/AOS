import AppKit
import Combine
import QuartzCore
import SwiftUI
import OSSenseKit

public struct NotchWindowFrameAnimationSpec: Sendable {
    public let duration: TimeInterval
    public let controlPoint1: CGPoint
    public let controlPoint2: CGPoint
}

// MARK: - NotchWindowController
//
// Owns the NSWindow + NotchViewModel + hosting view per notch-dev-guide
// §3.2 / §3.4. The window's frame covers the top strip of the screen at panel
// height (240) so the SwiftUI tree is free to render the closed bar, the
// expanded panel, and the edge-highlight overlay all from the same hosting
// view without re-laying-out the OS-level window.
//
// Region-based click-through is implemented at the window level: a global
// mouse-location stream toggles `window.ignoresMouseEvents` based on whether
// the cursor is over `viewModel.mouseActiveRect`. This is the only reliable
// way on macOS — `NSHostingView` returns self from `hitTest` for any point
// in its bounds (even where SwiftUI has no view), so neither view-level
// `hitTest` overrides nor "make the SwiftUI tree small" tricks can produce
// real click-through. Toggling `ignoresMouseEvents` makes the window
// transparent to mouse events at the OS level so clicks outside the visible
// silhouette reach the underlying app directly.

@MainActor
public final class NotchWindowController {
    private var window: NotchWindow?
    private var hostingView: NSHostingView<NotchView>?
    private var viewModel: NotchViewModel?
    private let screenFrame: CGRect
    private let topStripHeight: CGFloat
    private var cancellables: Set<AnyCancellable> = []
    private var lastAppliedPlacement: NotchPlacement = .attachedTop
    private var deferredWindowFrameTask: Task<Void, Never>?
    private var deferredWindowFrameTarget: CGRect?
    private var deferredWindowFramePlacement: NotchPlacement?
    private static var modalSuppression = ModalOverlaySuppressionState()
    private static weak var modalWindow: NotchWindow?
    private static weak var modalWindowController: NotchWindowController?
    private static var modalNotificationCancellables: Set<AnyCancellable> = []
    public nonisolated static let edgeDockFrameAnimation = NotchWindowFrameAnimationSpec(
        duration: 0.32,
        controlPoint1: CGPoint(x: 0.16, y: 1.0),
        controlPoint2: CGPoint(x: 0.3, y: 1.0)
    )
    public nonisolated static let detachedWindowShrinkDelay: TimeInterval = 0.32

    public enum WindowFrameUpdatePlan: Equatable, Sendable {
        case set(CGRect, animated: Bool)
        case deferSet(CGRect, delay: TimeInterval)
        case keepDeferred(CGRect)
    }

    public init(
        senseStore: SenseStore,
        agentService: AgentService,
        sessionService: SessionService,
        providerService: ProviderService,
        configService: ConfigService,
        permissionsService: PermissionsService,
        visualCapturePolicyStore: VisualCapturePolicyStore,
        permissionApprovalService: PermissionApprovalService?,
        screen: NSScreen
    ) {
        let screenFrame = screen.frame
        let notchSize = screen.notchSize
        let deviceNotchRect = Self.makeDeviceNotchRect(screen: screen, notchSize: notchSize)
        self.screenFrame = screenFrame

        let viewModel = NotchViewModel(
            senseStore: senseStore,
            agentService: agentService,
            sessionService: sessionService,
            providerService: providerService,
            configService: configService,
            permissionsService: permissionsService,
            visualCapturePolicyStore: visualCapturePolicyStore,
            permissionApprovalService: permissionApprovalService,
            screenRect: screenFrame,
            deviceNotchRect: deviceNotchRect
        )
        viewModel.bindEvents(.shared, agent: agentService)
        self.viewModel = viewModel

        // The NSWindow strip is sized to the panel's MAX height PLUS the
        // tray's MAX height — the dynamically-grown panel never extends past
        // its budget (history ScrollView scrolls past it), and the system
        // tray drawer that pokes out below adds its own ceiling on top.
        let panelHeight = viewModel.notchOpenedMaxHeight + viewModel.notchTrayMaxHeight
        self.topStripHeight = panelHeight
        let topStrip = Self.makeTopStripRect(screenFrame: screenFrame, panelHeight: panelHeight)

        let win = NotchWindow(
            contentRect: screenFrame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        win.setFrame(topStrip, display: true)
        let hosting = NSHostingView(rootView: NotchView(viewModel: viewModel))
        hosting.autoresizingMask = [.width, .height]
        win.contentView = hosting
        win.orderFrontRegardless()
        self.window = win
        self.hostingView = hosting
        Self.modalWindow = win
        Self.modalWindowController = self

        bindClickThrough(window: win, viewModel: viewModel)
        Self.installSystemModalSuppressionObservers()
        Self.applyActiveSystemModalSuppression(window: win, state: Self.modalSuppression)
    }

    /// Subscribe to global mouse-location + status-change streams and flip
    /// `ignoresMouseEvents` so the window only intercepts clicks while the
    /// cursor is over the visible notch silhouette. Seed from the current
    /// cursor position so the first click after the window appears already
    /// behaves correctly.
    private func bindClickThrough(window: NotchWindow, viewModel: NotchViewModel) {
        Self.applyClickThrough(window: window, viewModel: viewModel, mouse: NSEvent.mouseLocation)
        EventMonitors.shared.mouseLocation
            .receive(on: DispatchQueue.main)
            .sink { [weak window, weak viewModel] location in
                guard let window, let viewModel else { return }
                guard !Self.modalSuppression.isActive else { return }
                Self.applyClickThrough(window: window, viewModel: viewModel, mouse: location)
                Self.applyEdgeReveal(window: window, viewModel: viewModel, mouse: location)
            }
            .store(in: &cancellables)

        EventMonitors.shared.mouseDragged
            .receive(on: DispatchQueue.main)
            .sink { [weak viewModel] _ in
                guard let viewModel, viewModel.isDetachDragging else { return }
                viewModel.updateDetachDrag(pointer: NSEvent.mouseLocation)
            }
            .store(in: &cancellables)

        EventMonitors.shared.mouseUp
            .receive(on: DispatchQueue.main)
            .sink { [weak viewModel] _ in
                guard let viewModel, viewModel.isDetachDragging else { return }
                viewModel.finishDetachDrag(pointer: NSEvent.mouseLocation)
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .notchStatusChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak window, weak viewModel] _ in
                guard let window, let viewModel else { return }
                guard !Self.modalSuppression.isActive else { return }
                Self.applyClickThrough(
                    window: window,
                    viewModel: viewModel,
                    mouse: NSEvent.mouseLocation
                )
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .notchPlacementChanged)
            .sink { [weak self, weak window, weak viewModel] _ in
                guard let self, let window, let viewModel else { return }
                let previousPlacement = self.lastAppliedPlacement
                let currentPlacement = viewModel.currentPlacement
                let plan = Self.windowFrameUpdatePlan(
                    from: previousPlacement,
                    to: currentPlacement,
                    screenFrame: self.screenFrame,
                    topStripHeight: self.topStripHeight,
                    pendingDeferredFrame: self.deferredWindowFrameTarget
                )
                self.applyWindowFrame(plan, to: window, appliedPlacement: currentPlacement)
                guard !Self.modalSuppression.isActive else { return }
                Self.applyClickThrough(
                    window: window,
                    viewModel: viewModel,
                    mouse: NSEvent.mouseLocation
                )
            }
            .store(in: &cancellables)

        // React to VoiceOver state flips so a user enabling/disabling VO
        // mid-session immediately gets the right click-through behavior
        // without having to move the mouse first.
        DistributedNotificationCenter.default()
            .publisher(for: Notification.Name("com.apple.accessibility.api"))
            .receive(on: DispatchQueue.main)
            .sink { [weak window, weak viewModel] _ in
                guard let window, let viewModel else { return }
                guard !Self.modalSuppression.isActive else { return }
                Self.applyClickThrough(
                    window: window,
                    viewModel: viewModel,
                    mouse: NSEvent.mouseLocation
                )
            }
            .store(in: &cancellables)
    }

    /// Hide the notch overlay while AppKit is running an app-modal dialog.
    /// Modal alerts are ordinary app windows; the notch panel sits above the
    /// status bar and can otherwise cover the alert's top region while the
    /// main UI is blocked by the modal loop. Sheet notifications cover the
    /// async AppKit sheet path; synchronous `runModal()` callers must bracket
    /// their call with `beginSystemModalPresentation()` / `endSystemModalPresentation()`.
    private static func installSystemModalSuppressionObservers() {
        guard modalNotificationCancellables.isEmpty else { return }

        NotificationCenter.default
            .publisher(for: NSWindow.willBeginSheetNotification)
            .receive(on: DispatchQueue.main)
            .sink { _ in
                Self.beginSystemModalPresentationForCurrentWindow()
            }
            .store(in: &modalNotificationCancellables)

        NotificationCenter.default
            .publisher(for: NSWindow.didEndSheetNotification)
            .receive(on: DispatchQueue.main)
            .sink { _ in
                Self.endSystemModalPresentationForCurrentWindow()
            }
            .store(in: &modalNotificationCancellables)
    }

    public func beginSystemModalPresentation() {
        Self.beginSystemModalPresentationForCurrentWindow()
    }

    public func endSystemModalPresentation() {
        Self.endSystemModalPresentationForCurrentWindow()
    }

    public func withSystemModalPresentation<T>(_ body: () throws -> T) rethrows -> T {
        beginSystemModalPresentation()
        defer { endSystemModalPresentation() }
        return try body()
    }

    @discardableResult
    private static func beginSystemModalPresentationForCurrentWindow() -> Bool {
        beginSystemModalSuppression(window: modalWindow, state: &modalSuppression)
        return true
    }

    @discardableResult
    private static func endSystemModalPresentationForCurrentWindow() -> Bool {
        let shouldRestore = endSystemModalSuppression(window: modalWindow, state: &modalSuppression)
        guard shouldRestore,
              let controller = modalWindowController,
              let window = controller.window,
              let viewModel = controller.viewModel else {
            return shouldRestore
        }
        applyClickThrough(window: window, viewModel: viewModel, mouse: NSEvent.mouseLocation)
        return shouldRestore
    }

    private static func applyClickThrough(
        window: NotchWindow,
        viewModel: NotchViewModel,
        mouse: NSPoint
    ) {
        // Click-through must NOT be applied while VoiceOver is running:
        // VO routes synthetic mouse + activation events through the same
        // hit-testing path; with `ignoresMouseEvents = true` the window
        // becomes invisible to assistive technology and the entire notch
        // UI is unreachable. Keeping the window mouse-active for VO users
        // costs nothing because they don't generate hover events that
        // would land on regions outside the silhouette.
        if NSWorkspace.shared.isVoiceOverEnabled {
            if window.ignoresMouseEvents {
                window.ignoresMouseEvents = false
            }
            return
        }
        if viewModel.isDetachDragging {
            if window.ignoresMouseEvents {
                window.ignoresMouseEvents = false
            }
            return
        }
        let shouldIgnore = Self.shouldIgnoreMouseEvents(
            mouse: mouse,
            mouseActiveRect: viewModel.mouseActiveRect
        )
        if window.ignoresMouseEvents != shouldIgnore {
            window.ignoresMouseEvents = shouldIgnore
        }
    }

    private static func applyEdgeReveal(
        window: NotchWindow,
        viewModel: NotchViewModel,
        mouse: NSPoint
    ) {
        switch viewModel.currentPlacement {
        case .attachedTop, .detached:
            return
        case let .edgeDock(_, _, _, triggerFrame, false):
            if triggerFrame.contains(mouse) {
                viewModel.revealEdgeDock()
            }
        case let .edgeDock(_, _, revealFrame, _, true):
            if !revealFrame.insetBy(dx: -24, dy: -24).contains(mouse) {
                viewModel.collapseEdgeDock()
            }
        }
    }

    nonisolated static func shouldIgnoreMouseEvents(
        mouse: NSPoint,
        mouseActiveRect: CGRect
    ) -> Bool {
        !mouseActiveRect.contains(mouse)
    }

    public nonisolated static func windowFrame(
        for placement: NotchPlacement,
        screenFrame: CGRect,
        topStripHeight: CGFloat
    ) -> CGRect {
        precondition(topStripHeight > 0, "Top strip height must be positive")

        switch placement {
        case .attachedTop:
            return makeTopStripRect(screenFrame: screenFrame, panelHeight: topStripHeight)
        case let .detached(frame):
            return frame
        case let .edgeDock(_, hiddenFrame, revealFrame, _, revealed):
            return revealed ? revealFrame : hiddenFrame
        }
    }

    public nonisolated static func shouldAnimateWindowFrame(
        from previous: NotchPlacement,
        to current: NotchPlacement
    ) -> Bool {
        if case .detached = previous,
           case .attachedTop = current {
            return true
        }

        if case .detached = previous,
           case let .edgeDock(_, _, _, _, revealed) = current {
            return !revealed
        }

        guard case let .edgeDock(previousEdge, previousHidden, previousReveal, previousTrigger, previousRevealed) = previous,
              case let .edgeDock(currentEdge, currentHidden, currentReveal, currentTrigger, currentRevealed) = current else {
            return false
        }
        return previousEdge == currentEdge
            && previousHidden == currentHidden
            && previousReveal == currentReveal
            && previousTrigger == currentTrigger
            && previousRevealed != currentRevealed
    }

    public nonisolated static func windowFrameUpdatePlan(
        from previous: NotchPlacement,
        to current: NotchPlacement,
        screenFrame: CGRect,
        topStripHeight: CGFloat,
        pendingDeferredFrame: CGRect? = nil
    ) -> WindowFrameUpdatePlan {
        let target = windowFrame(
            for: current,
            screenFrame: screenFrame,
            topStripHeight: topStripHeight
        )

        if case let .detached(previousFrame) = previous,
           case let .detached(currentFrame) = current {
            let shouldWaitForSwiftUIShrink =
                currentFrame.width < previousFrame.width
                || currentFrame.height < previousFrame.height
            let keepsResizeAnchor =
                currentFrame.maxY == previousFrame.maxY
                && (
                    currentFrame.minX == previousFrame.minX
                    || currentFrame.maxX == previousFrame.maxX
                )
            if shouldWaitForSwiftUIShrink && keepsResizeAnchor {
                if pendingDeferredFrame == target {
                    return .keepDeferred(target)
                }
                return .deferSet(target, delay: detachedWindowShrinkDelay)
            }
            return .set(target, animated: false)
        }

        return .set(
            target,
            animated: shouldAnimateWindowFrame(from: previous, to: current)
        )
    }

    private func applyWindowFrame(
        _ plan: WindowFrameUpdatePlan,
        to window: NotchWindow,
        appliedPlacement: NotchPlacement
    ) {
        switch plan {
        case let .set(frame, animated):
            cancelDeferredWindowFrame()
            Self.applyWindowFrame(frame, to: window, animate: animated)
            lastAppliedPlacement = appliedPlacement
        case let .deferSet(frame, delay):
            cancelDeferredWindowFrame()
            deferredWindowFrameTarget = frame
            deferredWindowFramePlacement = appliedPlacement
            deferredWindowFrameTask = Task { @MainActor [weak self, weak window] in
                let milliseconds = Int((delay * 1_000).rounded())
                try? await Task.sleep(for: .milliseconds(milliseconds))
                guard !Task.isCancelled, let self, let window else { return }
                Self.applyWindowFrame(frame, to: window, animate: false)
                self.lastAppliedPlacement = self.deferredWindowFramePlacement ?? appliedPlacement
                self.deferredWindowFrameTask = nil
                self.deferredWindowFrameTarget = nil
                self.deferredWindowFramePlacement = nil
            }
        case .keepDeferred:
            deferredWindowFramePlacement = appliedPlacement
        }
    }

    private func cancelDeferredWindowFrame() {
        deferredWindowFrameTask?.cancel()
        deferredWindowFrameTask = nil
        deferredWindowFrameTarget = nil
        deferredWindowFramePlacement = nil
    }

    private static func applyWindowFrame(
        _ frame: CGRect,
        to window: NotchWindow,
        animate: Bool
    ) {
        guard animate, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            window.setFrame(frame, display: true, animate: false)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            let spec = edgeDockFrameAnimation
            context.duration = spec.duration
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: Float(spec.controlPoint1.x),
                Float(spec.controlPoint1.y),
                Float(spec.controlPoint2.x),
                Float(spec.controlPoint2.y)
            )
            window.animator().setFrame(frame, display: true)
        }
    }

    struct ModalOverlaySuppressionState: Equatable {
        var depth: Int = 0
        var wasVisibleBeforeFirstModal: Bool = false

        var isActive: Bool { depth > 0 }
    }

    static func beginSystemModalSuppression(
        window: NotchWindow?,
        state: inout ModalOverlaySuppressionState
    ) {
        precondition(state.depth >= 0, "Modal suppression depth cannot be negative")
        if state.depth == 0 {
            state.wasVisibleBeforeFirstModal = window?.isVisible ?? false
            if let window {
                suppressWindowForSystemModal(window)
            }
        }
        state.depth += 1
    }

    @discardableResult
    static func endSystemModalSuppression(
        window: NotchWindow?,
        state: inout ModalOverlaySuppressionState
    ) -> Bool {
        precondition(state.depth > 0, "Cannot end modal suppression that has not begun")
        state.depth -= 1
        guard state.depth == 0 else { return false }

        let shouldRestore = state.wasVisibleBeforeFirstModal
        state.wasVisibleBeforeFirstModal = false
        if shouldRestore, let window {
            window.orderFrontRegardless()
        }
        return shouldRestore
    }

    static func applyActiveSystemModalSuppression(
        window: NotchWindow,
        state: ModalOverlaySuppressionState
    ) {
        guard state.isActive else { return }
        suppressWindowForSystemModal(window)
    }

    private static func suppressWindowForSystemModal(_ window: NotchWindow) {
        window.ignoresMouseEvents = true
        if window.isVisible {
            window.orderOut(nil)
        }
    }

    /// Tear down per notch-dev-guide §3.4: cancel subscriptions, drop view
    /// hierarchy, close + nil out the window. Called by CompositionRoot when
    /// the screen configuration changes (so we can rebuild on the new
    /// built-in display).
    public func destroy() {
        deferredWindowFrameTask?.cancel()
        deferredWindowFrameTask = nil
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        viewModel?.destroy()
        viewModel = nil
        if Self.modalWindow === window {
            Self.modalWindow = nil
        }
        if Self.modalWindowController === self {
            Self.modalWindowController = nil
        }
        window?.close()
        window?.contentView = nil
        window = nil
        hostingView = nil
    }

    deinit {
        // `destroy()` must run on @MainActor; callers are expected to invoke
        // it explicitly. We don't dispatch back here because deinit can run
        // on arbitrary threads.
    }

    public nonisolated static func makeTopStripRect(
        screenFrame: CGRect,
        panelHeight: CGFloat
    ) -> CGRect {
        precondition(panelHeight > 0, "Notch panel height must be positive")
        return CGRect(
            x: screenFrame.minX,
            y: screenFrame.maxY - panelHeight,
            width: screenFrame.width,
            height: panelHeight
        )
    }

    public nonisolated static func makeDeviceNotchRect(
        screenFrame: CGRect,
        notchHeight: CGFloat,
        auxiliaryTopLeftWidth: CGFloat,
        auxiliaryTopRightWidth: CGFloat
    ) -> CGRect {
        precondition(notchHeight > 0, "Device notch height must be positive")
        precondition(auxiliaryTopLeftWidth > 0, "Auxiliary top-left width must be positive")
        precondition(auxiliaryTopRightWidth > 0, "Auxiliary top-right width must be positive")

        let width = screenFrame.width - auxiliaryTopLeftWidth - auxiliaryTopRightWidth
        precondition(width > 0, "Device notch width must be positive")

        return CGRect(
            x: screenFrame.minX + auxiliaryTopLeftWidth,
            y: screenFrame.maxY - notchHeight,
            width: width,
            height: notchHeight
        )
    }

    public nonisolated static func makeCenteredDeviceNotchRect(
        screenFrame: CGRect,
        notchSize: CGSize
    ) -> CGRect {
        precondition(notchSize.width > 0, "Virtual notch width must be positive")
        precondition(notchSize.height > 0, "Virtual notch height must be positive")
        return CGRect(
            x: screenFrame.midX - notchSize.width / 2,
            y: screenFrame.maxY - notchSize.height,
            width: notchSize.width,
            height: notchSize.height
        )
    }

    public nonisolated static func makeNotchCenterXInWindow(
        screenFrame: CGRect,
        deviceNotchRect: CGRect
    ) -> CGFloat {
        deviceNotchRect.midX - screenFrame.minX
    }

    private static func makeDeviceNotchRect(screen: NSScreen, notchSize: CGSize) -> CGRect {
        if screen.safeAreaInsets.top > 0 {
            guard let leftWidth = screen.auxiliaryTopLeftArea?.width,
                  let rightWidth = screen.auxiliaryTopRightArea?.width else {
                preconditionFailure("Notched display must expose auxiliary top areas")
            }

            return makeDeviceNotchRect(
                screenFrame: screen.frame,
                notchHeight: screen.safeAreaInsets.top,
                auxiliaryTopLeftWidth: leftWidth,
                auxiliaryTopRightWidth: rightWidth
            )
        }

        return makeCenteredDeviceNotchRect(screenFrame: screen.frame, notchSize: notchSize)
    }
}
