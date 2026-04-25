import AppKit
import Combine
import SwiftUI
import AOSOSSenseKit

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
// the cursor is over `viewModel.visibleHotRect`. This is the only reliable
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
    private var cancellables: Set<AnyCancellable> = []

    public init(senseStore: SenseStore, agentService: AgentService, providerService: ProviderService, configService: ConfigService, screen: NSScreen) {
        let screenFrame = screen.frame
        let notchSize = screen.notchSize
        let deviceNotchRect = Self.makeDeviceNotchRect(screen: screen, notchSize: notchSize)

        let viewModel = NotchViewModel(
            senseStore: senseStore,
            agentService: agentService,
            providerService: providerService,
            configService: configService,
            screenRect: screenFrame,
            deviceNotchRect: deviceNotchRect
        )
        viewModel.bindEvents(.shared, agent: agentService)
        self.viewModel = viewModel

        // The NSWindow strip is sized to the silhouette's MAX height — the
        // dynamically-grown panel never extends past it, so once the
        // conversation outgrows this budget the history ScrollView scrolls.
        let panelHeight = viewModel.notchOpenedMaxHeight
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

        bindClickThrough(window: win, viewModel: viewModel)
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
                Self.applyClickThrough(window: window, viewModel: viewModel, mouse: location)
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .aosNotchStatusChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak window, weak viewModel] _ in
                guard let window, let viewModel else { return }
                Self.applyClickThrough(
                    window: window,
                    viewModel: viewModel,
                    mouse: NSEvent.mouseLocation
                )
            }
            .store(in: &cancellables)
    }

    private static func applyClickThrough(
        window: NotchWindow,
        viewModel: NotchViewModel,
        mouse: NSPoint
    ) {
        let shouldIgnore = !viewModel.visibleHotRect.contains(mouse)
        if window.ignoresMouseEvents != shouldIgnore {
            window.ignoresMouseEvents = shouldIgnore
        }
    }

    /// Tear down per notch-dev-guide §3.4: cancel subscriptions, drop view
    /// hierarchy, close + nil out the window. Called by CompositionRoot when
    /// the screen configuration changes (so we can rebuild on the new
    /// built-in display).
    public func destroy() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        viewModel?.destroy()
        viewModel = nil
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
