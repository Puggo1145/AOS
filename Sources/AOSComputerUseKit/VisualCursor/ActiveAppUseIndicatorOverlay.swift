import AppKit
import CoreGraphics
import Foundation
import QuartzCore

// MARK: - ActiveAppUseIndicatorState
//
// Pure lifecycle helper for the visual "agent owns this app right now"
// indicator. Each activation returns a generation token; only the newest token
// may extend the active lease, so a stale completion from a previous app cannot
// keep the indicator alive after the agent has switched to a different app.

public struct ActiveAppUseTarget: Equatable, Sendable {
    public let pid: pid_t
    public let windowId: CGWindowID

    public init(pid: pid_t, windowId: CGWindowID) {
        self.pid = pid
        self.windowId = windowId
    }
}

public struct ActiveAppUseIndicatorToken: Equatable, Sendable {
    fileprivate let generation: UInt64
}

struct ActiveAppUseIndicatorState: Sendable {
    private var generation: UInt64 = 0
    private(set) var activeTarget: ActiveAppUseTarget?
    private(set) var leaseExpiresAt: TimeInterval?

    init() {}

    mutating func activate(
        _ target: ActiveAppUseTarget,
        now: TimeInterval,
        leaseDuration: TimeInterval
    ) -> ActiveAppUseIndicatorToken {
        generation &+= 1
        activeTarget = target
        leaseExpiresAt = now + leaseDuration
        return ActiveAppUseIndicatorToken(generation: generation)
    }

    mutating func pin(_ target: ActiveAppUseTarget) {
        generation &+= 1
        activeTarget = target
        leaseExpiresAt = nil
    }

    mutating func extend(
        _ token: ActiveAppUseIndicatorToken,
        now: TimeInterval,
        leaseDuration: TimeInterval
    ) {
        guard token.generation == generation else {
            return
        }
        leaseExpiresAt = now + leaseDuration
    }

    mutating func clearExpired(now: TimeInterval) {
        guard let leaseExpiresAt, now >= leaseExpiresAt else {
            return
        }
        forceClear()
    }

    mutating func forceClear() {
        activeTarget = nil
        leaseExpiresAt = nil
    }
}

enum ActiveAppUseIndicatorCapsuleGeometry {
    static let height: CGFloat = 26
    static let minimumWidth: CGFloat = 168
    static let horizontalPadding: CGFloat = 16
    static let topInset: CGFloat = 10

    static func panelFrame(in windowFrame: CGRect) -> CGRect {
        windowFrame
    }

    static func capsuleFrame(in overlayBounds: CGRect, labelWidth: CGFloat) -> CGRect {
        let width = min(
            max(labelWidth + horizontalPadding * 2, minimumWidth),
            max(overlayBounds.width - 24, 1)
        )
        return CGRect(
            x: overlayBounds.midX - width / 2,
            y: overlayBounds.maxY - topInset - height,
            width: width,
            height: height
        )
    }
}

enum ActiveAppUseIndicatorGlowStyle {
    static let standardWindowCornerRadius: CGFloat = 10
    static let innerEdgeInset: CGFloat = 1
    static let innerGlowDepth: Int = 54
    static let staticIntensity: CGFloat = 0.72

    static func cornerRadius(for bounds: CGRect) -> CGFloat {
        min(standardWindowCornerRadius, max(min(bounds.width, bounds.height) / 2 - innerEdgeInset, 0))
    }

    static func breathIntensity(phase: CGFloat, reduceMotion: Bool) -> CGFloat {
        if reduceMotion {
            return 0.7
        }

        return 0.38 + (sin(phase) + 1) * 0.31
    }
}

enum ActiveAppUseIndicatorRefreshPolicy {
    // WindowServer queries and relative ordering are expensive enough to
    // affect the notch UI when performed at display cadence. The drag monitor
    // still performs immediate refreshes while a window is being moved.
    static let windowPollInterval: TimeInterval = 0.25
    static let breathHalfCycleDuration: TimeInterval = 1
}

enum ActiveAppUseIndicatorWindowLevel {
    // The indicator describes active background control. It must remain visible
    // even when the controlled app is not the frontmost app, but stay below the
    // notch window (`statusBar + 8`) so the shell chrome remains authoritative.
    static let overlay = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
}

struct ActiveAppUseIndicatorOrderingState {
    private var orderedWindowId: CGWindowID?
    private var orderedLayer: Int?

    mutating func shouldOrderAbove(
        windowId: CGWindowID,
        layer: Int,
        panelIsVisible: Bool
    ) -> Bool {
        guard panelIsVisible,
              orderedWindowId == windowId,
              orderedLayer == layer
        else {
            orderedWindowId = windowId
            orderedLayer = layer
            return true
        }
        return false
    }

    mutating func reset() {
        orderedWindowId = nil
        orderedLayer = nil
    }
}

@MainActor
public enum ActiveAppUseIndicatorOverlay {
    private static let leaseDuration: TimeInterval = 6
    private static var state = ActiveAppUseIndicatorState()
    private static var orderingState = ActiveAppUseIndicatorOrderingState()
    private static var panel: ActiveAppUseIndicatorPanel?
    private static var overlayView: ActiveAppUseIndicatorView?
    private static var followTimer: Timer?
    private static var dragMonitor: Any?

    public static func activate(_ target: ActiveAppUseTarget) -> ActiveAppUseIndicatorToken {
        let token = state.activate(
            target,
            now: currentTime(),
            leaseDuration: leaseDuration
        )
        preparePanelIfNeeded()
        updatePanel(for: target)
        startFollowing()
        return token
    }

    public static func pin(_ target: ActiveAppUseTarget) {
        state.pin(target)
        preparePanelIfNeeded()
        updatePanel(for: target)
        startFollowing()
    }

    public static func extend(_ token: ActiveAppUseIndicatorToken) {
        state.extend(
            token,
            now: currentTime(),
            leaseDuration: leaseDuration
        )
        if let target = state.activeTarget {
            updatePanel(for: target)
            startFollowing()
            return
        }
        hidePanel()
    }

    public static func forceClear() {
        state.forceClear()
        hidePanel()
    }

    public static func reset() {
        forceClear()
    }

    private static func preparePanelIfNeeded() {
        guard panel == nil else { return }

        let panel = ActiveAppUseIndicatorPanel(
            contentRect: CGRect(
                x: 0,
                y: 0,
                width: ActiveAppUseIndicatorCapsuleGeometry.minimumWidth,
                height: ActiveAppUseIndicatorCapsuleGeometry.height
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = ActiveAppUseIndicatorWindowLevel.overlay
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle,
        ]
        panel.animationBehavior = .none
        // The capsule is status decoration for sighted users. It must not
        // become an accessibility focus stop while the user continues using
        // the target app underneath it.
        panel.setAccessibilityElement(false)

        let view = ActiveAppUseIndicatorView(frame: panel.contentRect(forFrameRect: panel.frame))
        view.setAccessibilityElement(false)
        panel.contentView = view

        self.panel = panel
        self.overlayView = view
    }

    private static func startFollowing() {
        overlayView?.updateBreathingAnimation()

        if followTimer == nil {
            let timer = Timer(timeInterval: ActiveAppUseIndicatorRefreshPolicy.windowPollInterval, repeats: true) { _ in
                MainActor.assumeIsolated {
                    updateActivePanelOrHide()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            followTimer = timer
        }

        guard dragMonitor == nil else { return }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { _ in
            MainActor.assumeIsolated {
                updateActivePanelOrHide()
            }
        }
    }

    private static func stopFollowing() {
        followTimer?.invalidate()
        followTimer = nil
        overlayView?.stopBreathingAnimation()
        if let dragMonitor {
            NSEvent.removeMonitor(dragMonitor)
            self.dragMonitor = nil
        }
    }

    private static func hidePanel() {
        stopFollowing()
        orderingState.reset()
        panel?.orderOut(nil)
    }

    private static func currentTime() -> TimeInterval {
        Date().timeIntervalSinceReferenceDate
    }

    private static func updateActivePanelOrHide() {
        state.clearExpired(now: currentTime())
        guard let target = state.activeTarget else {
            hidePanel()
            return
        }
        updatePanel(for: target)
    }

    private static func updatePanel(for target: ActiveAppUseTarget) {
        guard let panel, let overlayView else { return }
        guard let info = WindowEnumerator.window(forId: target.windowId),
              info.pid == target.pid,
              info.isOnScreen,
              info.bounds.width > 1,
              info.bounds.height > 1
        else {
            state.forceClear()
            hidePanel()
            return
        }

        guard let windowFrame = appKitRect(fromCGWindowBounds: info.bounds.cgRect) else {
            state.forceClear()
            hidePanel()
            return
        }

        let frame = ActiveAppUseIndicatorCapsuleGeometry.panelFrame(in: windowFrame)
        panel.level = ActiveAppUseIndicatorWindowLevel.overlay
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
            overlayView.frame = CGRect(origin: .zero, size: frame.size)
            overlayView.needsDisplay = true
        }
        overlayView.updateBreathingAnimation()

        if orderingState.shouldOrderAbove(
            windowId: target.windowId,
            layer: info.layer,
            panelIsVisible: panel.isVisible
        ) {
            panel.order(.above, relativeTo: Int(target.windowId))
        }
    }

    /// CGWindowList uses top-left, y-down display coordinates. NSPanel frames
    /// use AppKit's bottom-left, y-up coordinates, and external displays can
    /// have non-zero offsets, so conversion is per display.
    private static func appKitRect(fromCGWindowBounds cgRect: CGRect) -> CGRect? {
        let anchor = CGPoint(x: cgRect.midX, y: cgRect.midY)
        for screen in NSScreen.screens {
            guard
                let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { continue }
            let cgFrame = CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
            guard cgFrame.contains(anchor) else { continue }
            let localX = cgRect.minX - cgFrame.minX
            let localY = cgRect.minY - cgFrame.minY
            return CGRect(
                x: screen.frame.minX + localX,
                y: screen.frame.maxY - localY - cgRect.height,
                width: cgRect.width,
                height: cgRect.height
            )
        }
        return nil
    }
}

private final class ActiveAppUseIndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ActiveAppUseIndicatorView: NSView {
    private static let animationKey = "ActiveAppUseIndicatorOpacityBreath"

    private let label = "agent is using this app"
    private let labelFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private lazy var attributedLabel = NSAttributedString(
        string: label,
        attributes: [
            .font: labelFont,
            .foregroundColor: NSColor.white,
        ]
    )
    private lazy var measuredLabelSize = attributedLabel.size()

    var labelWidth: CGFloat {
        measuredLabelSize.width
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    func updateBreathingAnimation() {
        guard let layer else { return }

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            stopBreathingAnimation()
            layer.opacity = 1
            return
        }

        guard layer.animation(forKey: Self.animationKey) == nil else { return }

        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.82
        animation.toValue = 1
        animation.duration = ActiveAppUseIndicatorRefreshPolicy.breathHalfCycleDuration
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: Self.animationKey)
    }

    func stopBreathingAnimation() {
        layer?.removeAnimation(forKey: Self.animationKey)
        layer?.opacity = 1
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.clear.setFill()
        dirtyRect.fill()

        drawWindowArcGlow()
        drawCapsule()
    }

    private func drawWindowArcGlow() {
        guard bounds.width > 48, bounds.height > 48 else { return }

        let shapeBounds = bounds.insetBy(
            dx: ActiveAppUseIndicatorGlowStyle.innerEdgeInset,
            dy: ActiveAppUseIndicatorGlowStyle.innerEdgeInset
        )
        let cornerRadius = ActiveAppUseIndicatorGlowStyle.cornerRadius(for: bounds)
        let windowShapePath = NSBezierPath(
            roundedRect: shapeBounds,
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )

        NSGraphicsContext.saveGraphicsState()
        windowShapePath.addClip()

        drawInnerGlow(
            path: windowShapePath,
            color: NSColor(calibratedRed: 0.03, green: 0.48, blue: 1.0, alpha: 1),
            intensity: ActiveAppUseIndicatorGlowStyle.staticIntensity
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawCapsule() {
        let capsuleFrame = ActiveAppUseIndicatorCapsuleGeometry.capsuleFrame(
            in: bounds,
            labelWidth: labelWidth
        )
        let path = NSBezierPath(
            roundedRect: capsuleFrame.insetBy(dx: 0.5, dy: 0.5),
            xRadius: capsuleFrame.height / 2,
            yRadius: capsuleFrame.height / 2
        )
        NSColor(calibratedRed: 0.01, green: 0.22, blue: 0.72, alpha: 0.94).setFill()
        path.fill()
        NSColor(calibratedRed: 0.02, green: 0.52, blue: 1.0, alpha: 0.82).setStroke()
        path.lineWidth = 1
        path.stroke()

        let textSize = measuredLabelSize
        attributedLabel.draw(in: CGRect(
            x: capsuleFrame.midX - textSize.width / 2,
            y: capsuleFrame.midY - textSize.height / 2,
            width: textSize.width,
            height: textSize.height
        ))
    }

    private func drawInnerGlow(
        path: NSBezierPath,
        color: NSColor,
        intensity: CGFloat
    ) {
        let maxDepth = min(
            ActiveAppUseIndicatorGlowStyle.innerGlowDepth,
            max(Int(min(bounds.width, bounds.height) / 2) - 2, 1)
        )

        for step in 0..<maxDepth {
            let progress = CGFloat(step) / CGFloat(max(maxDepth - 1, 1))
            let alpha = pow(1 - progress, 2.15) * 0.44 * intensity
            let inset = ActiveAppUseIndicatorGlowStyle.innerEdgeInset + CGFloat(step)
            let rect = bounds.insetBy(dx: inset, dy: inset)
            let radius = max(ActiveAppUseIndicatorGlowStyle.cornerRadius(for: bounds) - CGFloat(step) * 0.18, 0)
            let innerPath = NSBezierPath(
                roundedRect: rect,
                xRadius: radius,
                yRadius: radius
            )

            color.withAlphaComponent(alpha).setStroke()
            innerPath.lineWidth = 1.25
            innerPath.lineCapStyle = .round
            innerPath.lineJoinStyle = .round
            innerPath.stroke()
        }

        color.withAlphaComponent(0.72 * intensity).setStroke()
        path.lineWidth = 1.1
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

}
