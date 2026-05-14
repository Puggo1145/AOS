import AppKit
import CoreGraphics
import Foundation
import QuartzCore

@MainActor
final class ComputerUseVirtualMouseOverlay {
    static let shared = ComputerUseVirtualMouseOverlay()

    private let windowSize = VirtualMouseGlyphMetrics.windowSize
    private let tipAnchor = VirtualMouseGlyphMetrics.tipAnchor
    private let visibilityNanoseconds: UInt64 = 10_000_000_000
    private var panel: ComputerUseVirtualMousePanel?
    private var cursorView: ComputerUseVirtualMouseView?
    private var hideTask: Task<Void, Never>?
    private var pulseTask: Task<Void, Never>?
    private var motionTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var currentTipPoint: CGPoint?
    private var restingTipPoint: CGPoint?
    private var visualDynamicsState: CursorVisualDynamicsState?
    private var generation: UInt64 = 0
    private var motionGeneration: UInt64 = 0
    private var idlePhase: CGFloat = 0
    private var isMoving = false

    private init() {}

    func handle(_ event: VirtualMouseEvent) async {
        switch event {
        case .move(let target):
            await show(at: target.point, clickProgress: 0)
        case .click(let target, _, let count):
            await showClick(at: target.point, count: count)
        case .drag(_, let point, _):
            await show(at: point, clickProgress: 0.2)
        case .settle(let target):
            await show(at: target.point, clickProgress: 0)
        case .dismiss:
            dismissImmediately()
        }
    }

    private func show(at screenStatePoint: CGPoint, clickProgress: CGFloat) async {
        pulseTask?.cancel()
        let point = Self.appKitPoint(fromScreenStatePoint: screenStatePoint)
        let panel = ensurePanel()
        let wasVisible = panel.isVisible
        panel.orderFrontRegardless()
        startIdleLoop()
        await move(panel: panel, to: point, animateFromCurrent: wasVisible)
        cursorView?.clickProgress = clickProgress
        scheduleHide()
    }

    private func showClick(at screenStatePoint: CGPoint, count: Int) async {
        let pulseCount = max(count, 1)
        await show(at: screenStatePoint, clickProgress: 0)
        pulseTask?.cancel()
        pulseTask = Task { @MainActor [weak self] in
            for index in 0..<pulseCount {
                if index > 0 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                await self?.pulseOnce()
            }
        }
        scheduleHide()
    }

    private func pulseOnce() async {
        let duration: TimeInterval = 0.16
        let start = CACurrentMediaTime()

        while true {
            guard !Task.isCancelled else {
                cursorView?.clickProgress = 0
                return
            }

            let elapsed = CACurrentMediaTime() - start
            let rawProgress = min(max(elapsed / duration, 0), 1)
            cursorView?.clickProgress = sin(rawProgress * .pi)

            if rawProgress >= 1 {
                break
            }

            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        cursorView?.clickProgress = 0
    }

    private func ensurePanel() -> ComputerUseVirtualMousePanel {
        if let panel {
            return panel
        }

        let frame = CGRect(origin: .zero, size: windowSize)
        let panel = ComputerUseVirtualMousePanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.level = .statusBar
        panel.title = "AOS Virtual Mouse"
        panel.setAccessibilityElement(false)

        let cursorView = ComputerUseVirtualMouseView(frame: frame)
        cursorView.setAccessibilityElement(false)
        panel.contentView = cursorView

        self.panel = panel
        self.cursorView = cursorView
        return panel
    }

    private func place(panel: NSPanel, using renderState: CursorVisualRenderState, clickProgress: CGFloat) {
        panel.setFrameOrigin(CGPoint(
            x: renderState.tipPosition.x - tipAnchor.x,
            y: renderState.tipPosition.y - tipAnchor.y
        ))
        cursorView?.rotation = renderState.rotation
        cursorView?.cursorBodyOffset = renderState.cursorBodyOffset
        cursorView?.fogOffset = renderState.fogOffset
        cursorView?.fogOpacity = renderState.fogOpacity
        cursorView?.fogScale = renderState.fogScale
        cursorView?.clickProgress = clickProgress
        currentTipPoint = renderState.tipPosition
    }

    private func move(panel: NSPanel, to point: CGPoint, animateFromCurrent: Bool) async {
        motionTask?.cancel()
        motionGeneration += 1
        let scheduledMotionGeneration = motionGeneration
        restingTipPoint = point
        guard
            animateFromCurrent,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            let currentTipPoint,
            hypot(point.x - currentTipPoint.x, point.y - currentTipPoint.y) > 1
        else {
            let renderState = advanceVisualDynamics(toward: point, at: CACurrentMediaTime())
            place(panel: panel, using: renderState, clickProgress: cursorView?.clickProgress ?? 0)
            return
        }

        let path = bestMotionPath(from: currentTipPoint, to: point)
        let measurement = path.measure(bounds: animationBounds(containing: currentTipPoint) ?? animationBounds(containing: point))
        let distance = hypot(point.x - currentTipPoint.x, point.y - currentTipPoint.y)
        let duration = VirtualMouseAnimationTiming.travelDuration(distance: distance, measurement: measurement)
        let springTargetDuration = OfficialCursorMotionModel.closeEnoughTime
        var progress: CGFloat = 0
        var springState = CursorMotionSpringState()
        let startedAt = CACurrentMediaTime()
        isMoving = true
        defer {
            if motionGeneration == scheduledMotionGeneration {
                isMoving = false
            }
        }

        while motionGeneration == scheduledMotionGeneration {
            let elapsed = CACurrentMediaTime() - startedAt
            let rawProgress = min(max(elapsed / duration, 0), 1)
            let springTime = CGFloat(rawProgress) * springTargetDuration
            (progress, springState) = CursorMotionProgressAnimator.advance(
                current: progress,
                state: springState,
                to: springTime
            )
            let sample = path.sample(at: progress)
            let renderState = advanceVisualDynamics(toward: sample.point, at: CACurrentMediaTime())
            place(panel: panel, using: renderState, clickProgress: 0)
            if rawProgress >= 1 {
                let finalState = advanceVisualDynamics(toward: point, at: CACurrentMediaTime())
                place(panel: panel, using: finalState, clickProgress: 0)
                return
            }
            try? await Task.sleep(nanoseconds: 8_333_333)
        }
    }

    private func startIdleLoop() {
        guard idleTask == nil else {
            return
        }

        idleTask = Task { @MainActor [weak self] in
            while true {
                guard let self, !Task.isCancelled else {
                    return
                }
                if let panel = self.panel, panel.isVisible, !self.isMoving {
                    self.idlePhase += 0.05
                    let idleAngleOffset = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                        ? 0
                        : sin(self.idlePhase * 0.8) * 0.09
                    let target = self.restingTipPoint ?? self.currentTipPoint
                    if let target {
                        let renderState = self.advanceVisualDynamics(
                            toward: target,
                            idleAngleOffset: idleAngleOffset,
                            at: CACurrentMediaTime()
                        )
                        self.place(panel: panel, using: renderState, clickProgress: self.cursorView?.clickProgress ?? 0)
                    }
                }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    private func stopIdleLoop() {
        idleTask?.cancel()
        idleTask = nil
        idlePhase = 0
    }

    private func scheduleHide(afterNanoseconds delay: UInt64? = nil) {
        generation += 1
        let scheduledGeneration = generation
        hideTask?.cancel()
        let resolvedDelay = delay ?? visibilityNanoseconds
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: resolvedDelay)
            guard let self, self.generation == scheduledGeneration else {
                return
            }
            self.panel?.orderOut(nil)
            self.stopIdleLoop()
            self.currentTipPoint = nil
            self.restingTipPoint = nil
            self.visualDynamicsState = nil
        }
    }

    private func dismissImmediately() {
        generation += 1
        motionGeneration += 1
        hideTask?.cancel()
        hideTask = nil
        pulseTask?.cancel()
        pulseTask = nil
        motionTask?.cancel()
        motionTask = nil
        isMoving = false
        stopIdleLoop()
        currentTipPoint = nil
        restingTipPoint = nil
        visualDynamicsState = nil
        cursorView?.rotation = 0
        cursorView?.cursorBodyOffset = CGVector(dx: 0, dy: 0)
        cursorView?.fogOffset = CGVector(dx: 0, dy: 0)
        panel?.orderOut(nil)
    }

    private func bestMotionPath(from start: CGPoint, to end: CGPoint) -> CursorMotionPath {
        let candidates = HeadingDrivenCursorMotionModel.makeCandidates(
            start: start,
            end: end,
            bounds: animationBounds(containing: start) ?? animationBounds(containing: end),
            startForward: currentCursorForwardVector(),
            endForward: restingCursorForwardVector()
        )
        return HeadingDrivenCursorMotionModel.chooseBestCandidate(from: candidates)?.path
            ?? CursorMotionPath(start: start, end: end)
    }

    private func currentCursorForwardVector() -> CGVector {
        let rotation = cursorView?.rotation ?? 0
        let heading = -VirtualMouseGlyphMetrics.targetNeutralHeading - rotation
        return CGVector(dx: cos(heading), dy: sin(heading))
    }

    private func restingCursorForwardVector() -> CGVector {
        let heading = -VirtualMouseGlyphMetrics.targetNeutralHeading
        return CGVector(dx: cos(heading), dy: sin(heading))
    }

    private func advanceVisualDynamics(
        toward targetTipPosition: CGPoint,
        idleAngleOffset: CGFloat = 0,
        at time: CFTimeInterval
    ) -> CursorVisualRenderState {
        if visualDynamicsState == nil {
            visualDynamicsState = CursorVisualDynamicsAnimator.state(
                at: targetTipPosition,
                time: CGFloat(time)
            )
        }

        let result = CursorVisualDynamicsAnimator.advance(
            state: visualDynamicsState ?? CursorVisualDynamicsAnimator.state(at: targetTipPosition, time: CGFloat(time)),
            targetTipPosition: targetTipPosition,
            targetTime: CGFloat(time),
            idleAngleOffset: idleAngleOffset,
            baseHeading: VirtualMouseGlyphMetrics.targetNeutralHeading,
            renderYAxisMultiplier: -1
        )
        visualDynamicsState = result.state
        return result.renderState
    }

    private func animationBounds(containing point: CGPoint) -> CGRect? {
        (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame
    }

    private static func appKitPoint(fromScreenStatePoint point: CGPoint) -> CGPoint {
        for screen in NSScreen.screens {
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayBounds = CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
            guard displayBounds.contains(point) else {
                continue
            }

            let localX = point.x - displayBounds.minX
            let localY = point.y - displayBounds.minY
            return CGPoint(
                x: screen.frame.minX + localX,
                y: screen.frame.maxY - localY
            )
        }
        return point
    }
}

private final class ComputerUseVirtualMousePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ComputerUseVirtualMouseView: NSView {
    var rotation: CGFloat = 0 {
        didSet {
            needsDisplay = true
        }
    }

    var cursorBodyOffset = CGVector(dx: 0, dy: 0) {
        didSet {
            needsDisplay = true
        }
    }

    var fogOffset = CGVector(dx: 0, dy: 0) {
        didSet {
            needsDisplay = true
        }
    }

    var fogOpacity: CGFloat = CursorVisualDynamicsConfiguration.officialInspired.fogOpacityBase {
        didSet {
            needsDisplay = true
        }
    }

    var fogScale: CGFloat = 1 {
        didSet {
            needsDisplay = true
        }
    }

    var clickProgress: CGFloat = 0 {
        didSet {
            needsDisplay = true
        }
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

        VirtualMouseGlyphRenderer.draw(
            in: bounds,
            context: context,
            state: VirtualMouseGlyphRenderState(
                rotation: rotation,
                cursorBodyOffset: cursorBodyOffset,
                fogOffset: fogOffset,
                fogOpacity: fogOpacity,
                fogScale: fogScale,
                clickProgress: clickProgress
            )
        )
    }
}
