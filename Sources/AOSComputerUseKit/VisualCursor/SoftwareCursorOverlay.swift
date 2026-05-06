import AppKit
import CoreGraphics
import Foundation
import QuartzCore

public enum VisualCursorSupport {
    public static var isEnabled: Bool {
        visualCursorEnabled(environment: ProcessInfo.processInfo.environment)
    }

    static func performOnMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                body()
            }
            return
        }

        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                body()
            }
        }
    }
}

func visualCursorEnabled(environment: [String: String]) -> Bool {
    // Default ON. Set `AOS_VISUAL_CURSOR=0` (or false/no/off) to disable.
    guard let rawValue = environment["AOS_VISUAL_CURSOR"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
        return true
    }

    return !["0", "false", "no", "off"].contains(rawValue)
}

func visualCursorPostInteractionIdleTimeout() -> TimeInterval {
    1
}

func visualCursorIdleRotationAmplitude() -> CGFloat {
    0.09
}

/// Mouse button vocabulary used by the visual overlay's pulse animation.
/// Mirrors `MouseInput.Button` but lives inside the VisualCursor subsystem
/// so the overlay has no compile-time dependency on the input layer.
public enum VisualCursorMouseButton: Sendable {
    case left
    case right
    case middle
}

struct VisualCursorIdlePose {
    let tipPosition: CGPoint
    let angleOffset: CGFloat
}

func visualCursorIdlePose(restingTipPosition: CGPoint, phase: CGFloat) -> VisualCursorIdlePose {
    VisualCursorIdlePose(
        tipPosition: restingTipPosition,
        angleOffset: sin(phase * 0.8) * visualCursorIdleRotationAmplitude()
    )
}

func visualCursorClampedTipPosition(
    _ tipPosition: CGPoint,
    visibleFrame: CGRect,
    geometry: CursorWindowGeometry
) -> CGPoint {
    let minX = visibleFrame.minX + geometry.tipAnchor.x
    let maxX = visibleFrame.maxX - (geometry.windowSize.width - geometry.tipAnchor.x)
    let minY = visibleFrame.minY + geometry.tipAnchor.y
    let maxY = visibleFrame.maxY - (geometry.windowSize.height - geometry.tipAnchor.y)

    return CGPoint(
        x: tipPosition.x.clamped(to: minX...maxX),
        y: tipPosition.y.clamped(to: minY...maxY)
    )
}

struct CursorVisualRenderState: Equatable {
    let tipPosition: CGPoint
    let rotation: CGFloat
    let cursorBodyOffset: CGVector
    let fogOffset: CGVector
    let fogOpacity: CGFloat
    let fogScale: CGFloat
    let appearanceScale: CGFloat
}

func visualCursorConstrainedRenderState(
    _ renderState: CursorVisualRenderState,
    visibleFrame: CGRect,
    geometry: CursorWindowGeometry
) -> CursorVisualRenderState {
    CursorVisualRenderState(
        tipPosition: visualCursorClampedTipPosition(
            renderState.tipPosition,
            visibleFrame: visibleFrame,
            geometry: geometry
        ),
        rotation: renderState.rotation,
        cursorBodyOffset: renderState.cursorBodyOffset,
        fogOffset: renderState.fogOffset,
        fogOpacity: renderState.fogOpacity,
        fogScale: renderState.fogScale,
        appearanceScale: renderState.appearanceScale
    )
}

/// Public entry point to clear the overlay (e.g. when an agent turn ends and
/// no further events are expected). Safe to call from any thread.
public func resetAOSVisualCursor() {
    VisualCursorSupport.performOnMain {
        SoftwareCursorOverlay.reset()
    }
}

struct CursorTargetWindow: Equatable, Sendable {
    let windowID: CGWindowID
    let layer: Int
}

struct CursorWindowGeometry {
    let windowSize: CGSize
    let tipAnchor: CGPoint

    func origin(forTipPosition tipPosition: CGPoint) -> CGPoint {
        CGPoint(
            x: tipPosition.x - tipAnchor.x,
            y: tipPosition.y - tipAnchor.y
        )
    }

    func tipPosition(forOrigin origin: CGPoint) -> CGPoint {
        CGPoint(
            x: origin.x + tipAnchor.x,
            y: origin.y + tipAnchor.y
        )
    }
}

private struct CursorArtwork {
    let geometry: CursorWindowGeometry
    static let active = CursorArtwork(
        geometry: CursorWindowGeometry(
            windowSize: SoftwareCursorGlyphMetrics.windowSize,
            tipAnchor: SoftwareCursorGlyphMetrics.tipAnchor
        ),
    )
}

@MainActor
enum SoftwareCursorOverlay {
    private static let artwork = CursorArtwork.active
    private static let travelDuration: TimeInterval = 0.3
    private static let appearanceDuration: TimeInterval = 0.3
    private static let disappearanceDuration: TimeInterval = 0.3
    private static var panel: CursorPanel?
    private static var cursorView: SoftwareCursorView?
    private static var restingTipPosition: CGPoint?
    private static var displayedTipPosition: CGPoint?
    private static var activeTargetWindow: CursorTargetWindow?
    private static var idleTimer: Timer?
    private static var hideTimer: Timer?
    private static var idlePhase: CGFloat = 0

    static func moveCursor(to targetPoint: CGPoint, in targetWindow: CursorTargetWindow?) {
        guard VisualCursorSupport.isEnabled, canPresentOverlay else {
            return
        }

        prepareWindowIfNeeded()
        stopIdleAnimation()
        cancelPendingHide()
        configureOrdering(relativeTo: targetWindow)

        let constrainedTarget = clampTipPosition(targetPoint)

        panel?.alphaValue = 1

        guard let startPoint = displayedTipPosition else {
            animateAppear(at: constrainedTarget)
            return
        }

        placeCursor(using: renderState(at: startPoint), clickProgress: 0)

        if distanceBetween(startPoint, constrainedTarget) > 2 {
            animateMove(from: startPoint, to: constrainedTarget, relativeTo: targetWindow)
        }
    }

    static func pulseClick(at targetPoint: CGPoint, clickCount: Int, mouseButton: VisualCursorMouseButton, in targetWindow: CursorTargetWindow?) {
        guard VisualCursorSupport.isEnabled, canPresentOverlay else {
            return
        }

        configureOrdering(relativeTo: targetWindow)
        let constrainedTarget = clampTipPosition(targetPoint)
        restingTipPosition = constrainedTarget
        animateClickPulse(at: constrainedTarget, clickCount: max(clickCount, 1), mouseButton: mouseButton)
        startIdleAnimation()
        scheduleHide(after: visualCursorPostInteractionIdleTimeout())
    }

    static func settle(at targetPoint: CGPoint, in targetWindow: CursorTargetWindow?) {
        guard VisualCursorSupport.isEnabled, canPresentOverlay else {
            return
        }

        configureOrdering(relativeTo: targetWindow)
        let constrainedTarget = clampTipPosition(targetPoint)
        restingTipPosition = constrainedTarget
        placeCursor(using: renderState(at: constrainedTarget), clickProgress: 0)
        startIdleAnimation()
        scheduleHide(after: visualCursorPostInteractionIdleTimeout())
    }

    static func reset() {
        stopIdleAnimation()
        cancelPendingHide()
        displayedTipPosition = nil
        restingTipPosition = nil
        activeTargetWindow = nil
        panel?.orderOut(nil)
    }

    private static var canPresentOverlay: Bool {
        !NSScreen.screens.isEmpty
    }

    private static func prepareWindowIfNeeded() {
        guard panel == nil else {
            return
        }

        let panel = CursorPanel(
            contentRect: CGRect(origin: .zero, size: artwork.geometry.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .normal
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        // The cursor panel is purely decorative — it must not appear in
        // the accessibility hierarchy or VoiceOver will land focus on it
        // while the agent operates apps.
        panel.setAccessibilityElement(false)

        let view = SoftwareCursorView(frame: CGRect(origin: .zero, size: artwork.geometry.windowSize))
        view.setAccessibilityElement(false)
        panel.contentView = view

        self.panel = panel
        self.cursorView = view
    }

    private static func configureOrdering(relativeTo targetWindow: CursorTargetWindow?) {
        configureOrdering(relativeTo: targetWindow, forceReorder: false)
    }

    private static func configureOrdering(relativeTo targetWindow: CursorTargetWindow?, forceReorder: Bool) {
        guard let panel else {
            return
        }

        let effectiveTargetWindow = targetWindow.flatMap { targetWindow in
            isWindowPresent(targetWindow.windowID) ? targetWindow : nil
        }

        let desiredLevel = NSWindow.Level(rawValue: effectiveTargetWindow?.layer ?? 0)
        if panel.level != desiredLevel {
            panel.level = desiredLevel
        }

        if shouldReorderCursorPanel(
            activeTargetWindow: activeTargetWindow,
            effectiveTargetWindow: effectiveTargetWindow,
            panelIsVisible: panel.isVisible,
            forceReorder: forceReorder
        ) {
            if let effectiveTargetWindow {
                panel.order(.above, relativeTo: Int(effectiveTargetWindow.windowID))
            } else {
                panel.orderFront(nil)
            }
            activeTargetWindow = effectiveTargetWindow
        }
    }

    private static func animateMove(from start: CGPoint, to end: CGPoint, relativeTo targetWindow: CursorTargetWindow?) {
        let startTime = CACurrentMediaTime()

        while true {
            refreshActiveOrderingIfNeeded()

            let elapsed = CGFloat(CACurrentMediaTime() - startTime)
            let linearProgress = (elapsed / max(CGFloat(travelDuration), 0.001)).clamped(to: 0...1)
            let easedProgress = easeInOutCubic(linearProgress)
            placeCursor(using: renderState(at: interpolate(from: start, to: end, progress: easedProgress)), clickProgress: 0)

            if linearProgress >= 1 {
                break
            }

            pumpFrame()
        }

        placeCursor(using: renderState(at: end), clickProgress: 0)
    }

    private static func animateAppear(at point: CGPoint) {
        let startTime = CACurrentMediaTime()

        while true {
            refreshActiveOrderingIfNeeded()

            let elapsed = CGFloat(CACurrentMediaTime() - startTime)
            let linearProgress = (elapsed / max(CGFloat(appearanceDuration), 0.001)).clamped(to: 0...1)
            placeCursor(
                using: renderState(at: point, appearanceScale: linearProgress),
                clickProgress: 0
            )

            if linearProgress >= 1 {
                break
            }

            pumpFrame()
        }

        placeCursor(using: renderState(at: point), clickProgress: 0)
    }

    private static func isWindowPresent(_ windowID: CGWindowID) -> Bool {
        guard windowID != 0,
              let windowInfo = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]]
        else {
            return false
        }

        return !windowInfo.isEmpty
    }

    private static func refreshActiveOrderingIfNeeded() {
        guard let activeTargetWindow else {
            return
        }

        if isWindowPresent(activeTargetWindow.windowID) {
            configureOrdering(relativeTo: activeTargetWindow, forceReorder: true)
            return
        }

        configureOrdering(relativeTo: nil)
    }

    private static func animateClickPulse(at point: CGPoint, clickCount: Int, mouseButton: VisualCursorMouseButton) {
        let pulseBias: CGFloat = mouseButton == .right ? 0.82 : 1

        for pulse in 0..<clickCount {
            let duration = 0.16
            let startTime = CACurrentMediaTime()

            while true {
                let elapsed = CACurrentMediaTime() - startTime
                let rawProgress = min(max(elapsed / duration, 0), 1)
                let clickProgress = sin(rawProgress * .pi) * pulseBias

                placeCursor(
                    using: renderState(at: point),
                    clickProgress: clickProgress
                )

                if rawProgress >= 1 {
                    break
                }

                pumpFrame()
            }

            if pulse < clickCount - 1 {
                pause(for: 0.05)
            }
        }

        placeCursor(using: renderState(at: point), clickProgress: 0)
    }

    private static func startIdleAnimation() {
        guard canPresentOverlay, let restingTipPosition else {
            return
        }

        idlePhase = 0
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard panel != nil, cursorView != nil else {
                    return
                }

                refreshActiveOrderingIfNeeded()

                idlePhase += 0.05
                let idlePose = visualCursorIdlePose(
                    restingTipPosition: restingTipPosition,
                    phase: idlePhase
                )

                placeCursor(
                    using: renderState(at: idlePose.tipPosition, rotation: idlePose.angleOffset),
                    clickProgress: 0
                )
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer

        placeCursor(using: renderState(at: restingTipPosition), clickProgress: 0)
    }

    private static func stopIdleAnimation() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private static func scheduleHide(after delay: TimeInterval) {
        cancelPendingHide()
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated {
                hideOverlay()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    private static func cancelPendingHide() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    private static func hideOverlay() {
        guard panel != nil else {
            return
        }

        stopIdleAnimation()
        cancelPendingHide()

        if let tipPosition = displayedTipPosition ?? restingTipPosition {
            animateDisappear(at: tipPosition)
            return
        }

        finishHidingPanel()
    }

    private static func animateDisappear(at point: CGPoint) {
        let startTime = CACurrentMediaTime()

        while true {
            refreshActiveOrderingIfNeeded()

            let elapsed = CGFloat(CACurrentMediaTime() - startTime)
            let linearProgress = (elapsed / max(CGFloat(disappearanceDuration), 0.001)).clamped(to: 0...1)
            placeCursor(
                using: renderState(at: point, appearanceScale: 1 - linearProgress),
                clickProgress: 0
            )

            if linearProgress >= 1 {
                break
            }

            pumpFrame()
        }

        finishHidingPanel()
    }

    private static func finishHidingPanel() {
        panel?.orderOut(nil)
        panel?.alphaValue = 1
        cursorView?.appearanceScale = 1
        displayedTipPosition = nil
        restingTipPosition = nil
        activeTargetWindow = nil
    }

    private static func renderState(
        at tipPosition: CGPoint,
        rotation: CGFloat = 0,
        appearanceScale: CGFloat = 1
    ) -> CursorVisualRenderState {
        CursorVisualRenderState(
            tipPosition: tipPosition,
            rotation: rotation,
            cursorBodyOffset: CGVector(dx: 0, dy: 0),
            fogOffset: CGVector(dx: 0, dy: 0),
            fogOpacity: 0.12,
            fogScale: 1,
            appearanceScale: appearanceScale.clamped(to: 0...1)
        )
    }

    private static func placeCursor(using renderState: CursorVisualRenderState, clickProgress: CGFloat) {
        guard let panel, let cursorView else {
            return
        }

        let constrainedRenderState = constrainedRenderStateForPlacement(renderState)
        panel.setFrameOrigin(artwork.geometry.origin(forTipPosition: constrainedRenderState.tipPosition))
        cursorView.rotation = constrainedRenderState.rotation
        cursorView.cursorBodyOffset = constrainedRenderState.cursorBodyOffset
        cursorView.fogOffset = constrainedRenderState.fogOffset
        cursorView.fogOpacity = constrainedRenderState.fogOpacity
        cursorView.fogScale = constrainedRenderState.fogScale
        cursorView.appearanceScale = constrainedRenderState.appearanceScale
        cursorView.clickProgress = clickProgress
        cursorView.needsDisplay = true
        cursorView.displayIfNeeded()
        displayedTipPosition = constrainedRenderState.tipPosition
    }

    private static func constrainedRenderStateForPlacement(_ renderState: CursorVisualRenderState) -> CursorVisualRenderState {
        guard let screen = screen(containing: renderState.tipPosition) ?? NSScreen.main ?? NSScreen.screens.first else {
            return renderState
        }

        return visualCursorConstrainedRenderState(
            renderState,
            visibleFrame: screen.visibleFrame,
            geometry: artwork.geometry
        )
    }

    private static func clampTipPosition(_ tipPosition: CGPoint) -> CGPoint {
        guard let screen = screen(containing: tipPosition) ?? NSScreen.main ?? NSScreen.screens.first else {
            return tipPosition
        }

        let visibleFrame = screen.visibleFrame
        return visualCursorClampedTipPosition(
            tipPosition,
            visibleFrame: visibleFrame,
            geometry: artwork.geometry
        )
    }

    private static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    private static func pumpFrame() {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(1 / 120))
    }

    private static func pause(for duration: TimeInterval) {
        let start = CACurrentMediaTime()
        while CACurrentMediaTime() - start < duration {
            pumpFrame()
        }
    }

    private static func distanceBetween(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(rhs.x - lhs.x, rhs.y - lhs.y)
    }

    private static func interpolate(from start: CGPoint, to end: CGPoint, progress: CGFloat) -> CGPoint {
        CGPoint(
            x: start.x + ((end.x - start.x) * progress),
            y: start.y + ((end.y - start.y) * progress)
        )
    }

    private static func easeInOutCubic(_ progress: CGFloat) -> CGFloat {
        let t = progress.clamped(to: 0...1)
        if t < 0.5 {
            return 4 * t * t * t
        }
        return 1 - pow(-2 * t + 2, 3) / 2
    }

}

extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

func shouldReorderCursorPanel(
    activeTargetWindow: CursorTargetWindow?,
    effectiveTargetWindow: CursorTargetWindow?,
    panelIsVisible: Bool,
    forceReorder: Bool
) -> Bool {
    forceReorder || activeTargetWindow != effectiveTargetWindow || panelIsVisible == false
}

private final class CursorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class SoftwareCursorView: NSView {
    var rotation: CGFloat = 0
    var cursorBodyOffset: CGVector = CGVector(dx: 0, dy: 0)
    var fogOffset: CGVector = CGVector(dx: 0, dy: 0)
    var fogOpacity: CGFloat = 0.12
    var fogScale: CGFloat = 1
    var appearanceScale: CGFloat = 1
    var clickProgress: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.clear.setFill()
        dirtyRect.fill()

        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        SoftwareCursorGlyphRenderer.draw(
            in: bounds,
            context: context,
            state: SoftwareCursorGlyphRenderState(
                rotation: rotation,
                cursorBodyOffset: cursorBodyOffset,
                fogOffset: fogOffset,
                fogOpacity: fogOpacity,
                fogScale: fogScale,
                appearanceScale: appearanceScale,
                clickProgress: clickProgress
            )
        )
    }
}
