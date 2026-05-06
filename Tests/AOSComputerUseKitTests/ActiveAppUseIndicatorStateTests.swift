import CoreGraphics
import Testing
@testable import AOSComputerUseKit

@Suite("Active app use indicator state")
struct ActiveAppUseIndicatorStateTests {
    @Test("activate keeps the target alive until its lease expires")
    func activateKeepsTargetUntilLeaseExpires() {
        var state = ActiveAppUseIndicatorState()
        let target = ActiveAppUseTarget(pid: 101, windowId: 202)

        _ = state.activate(target, now: 10, leaseDuration: 6)

        #expect(state.activeTarget == target)
        state.clearExpired(now: 15)
        #expect(state.activeTarget == target)

        state.clearExpired(now: 16)
        #expect(state.activeTarget == nil)
    }

    @Test("activating a new target replaces the previous app immediately")
    func activatingNewTargetReplacesPreviousTarget() {
        var state = ActiveAppUseIndicatorState()
        let first = ActiveAppUseTarget(pid: 101, windowId: 202)
        let second = ActiveAppUseTarget(pid: 303, windowId: 404)

        _ = state.activate(first, now: 10, leaseDuration: 6)
        _ = state.activate(second, now: 11, leaseDuration: 6)

        #expect(state.activeTarget == second)
    }

    @Test("an old lease expiry cannot clear a newer target")
    func oldLeaseExpiryDoesNotClearNewTarget() {
        var state = ActiveAppUseIndicatorState()
        let first = ActiveAppUseTarget(pid: 101, windowId: 202)
        let second = ActiveAppUseTarget(pid: 303, windowId: 404)

        _ = state.activate(first, now: 10, leaseDuration: 6)
        _ = state.activate(second, now: 15, leaseDuration: 6)

        state.clearExpired(now: 16)
        #expect(state.activeTarget == second)
    }

    @Test("finishing the current operation extends only the current target")
    func extendCurrentOperationLease() {
        var state = ActiveAppUseIndicatorState()
        let first = ActiveAppUseTarget(pid: 101, windowId: 202)
        let second = ActiveAppUseTarget(pid: 303, windowId: 404)

        let firstToken = state.activate(first, now: 10, leaseDuration: 6)
        _ = state.activate(second, now: 11, leaseDuration: 6)
        state.extend(firstToken, now: 20, leaseDuration: 6)

        state.clearExpired(now: 17)
        #expect(state.activeTarget == nil)
    }

    @Test("finishing the current operation extends the visible lease")
    func extendCurrentOperationKeepsTargetVisible() {
        var state = ActiveAppUseIndicatorState()
        let target = ActiveAppUseTarget(pid: 101, windowId: 202)

        let token = state.activate(target, now: 10, leaseDuration: 6)
        state.extend(token, now: 15, leaseDuration: 6)

        state.clearExpired(now: 16)
        #expect(state.activeTarget == target)

        state.clearExpired(now: 21)
        #expect(state.activeTarget == nil)
    }

    @Test("force clear removes the active target regardless of lease")
    func forceClearRemovesTarget() {
        var state = ActiveAppUseIndicatorState()
        let target = ActiveAppUseTarget(pid: 101, windowId: 202)

        _ = state.activate(target, now: 10, leaseDuration: 6)
        state.forceClear()

        #expect(state.activeTarget == nil)
    }

    @Test("dev mode can pin an indicator target until manual clear")
    func devModePinKeepsTargetUntilManualClear() {
        var state = ActiveAppUseIndicatorState()
        let target = ActiveAppUseTarget(pid: 101, windowId: 202)

        state.pin(target)

        state.clearExpired(now: .greatestFiniteMagnitude)
        #expect(state.activeTarget == target)

        state.forceClear()
        #expect(state.activeTarget == nil)
    }

    @Test("overlay frame covers the target window so glow is not clipped")
    func overlayFrameCoversTargetWindow() {
        let windowFrame = CGRect(x: 20, y: 40, width: 800, height: 500)

        let panelFrame = ActiveAppUseIndicatorCapsuleGeometry.panelFrame(in: windowFrame)

        #expect(panelFrame == windowFrame)
    }

    @Test("capsule frame stays small and centered at the overlay top")
    func capsuleFrameIsSmallAndTopCentered() {
        let overlayBounds = CGRect(x: 0, y: 0, width: 800, height: 500)

        let capsuleFrame = ActiveAppUseIndicatorCapsuleGeometry.capsuleFrame(
            in: overlayBounds,
            labelWidth: 124
        )

        #expect(capsuleFrame.width == 168)
        #expect(capsuleFrame.height == 26)
        #expect(capsuleFrame.midX == overlayBounds.midX)
        #expect(capsuleFrame.maxY == overlayBounds.maxY - 10)
        #expect(capsuleFrame.width < overlayBounds.width)
        #expect(capsuleFrame.height < overlayBounds.height)
    }

    @Test("breathing glow intensity changes unless reduce motion is enabled")
    func breathingGlowIntensityRespectsReduceMotion() {
        let dim = ActiveAppUseIndicatorGlowStyle.breathIntensity(phase: -.pi / 2, reduceMotion: false)
        let bright = ActiveAppUseIndicatorGlowStyle.breathIntensity(phase: .pi / 2, reduceMotion: false)
        let reducedA = ActiveAppUseIndicatorGlowStyle.breathIntensity(phase: -.pi / 2, reduceMotion: true)
        let reducedB = ActiveAppUseIndicatorGlowStyle.breathIntensity(phase: .pi / 2, reduceMotion: true)

        #expect(dim < bright)
        #expect(bright - dim >= 0.6)
        #expect(reducedA == reducedB)
    }

    @Test("window glow uses a stable macOS-style corner radius")
    func windowGlowUsesStableCornerRadius() {
        let normalWindow = CGRect(x: 0, y: 0, width: 800, height: 500)
        let tinyWindow = CGRect(x: 0, y: 0, width: 12, height: 12)

        #expect(ActiveAppUseIndicatorGlowStyle.cornerRadius(for: normalWindow) == 10)
        #expect(ActiveAppUseIndicatorGlowStyle.cornerRadius(for: tinyWindow) == 5)
    }

    @Test("window polling is slower than render cadence")
    func windowPollingIsSlowerThanRenderCadence() {
        #expect(ActiveAppUseIndicatorRefreshPolicy.windowPollInterval >= 0.25)
    }

    @Test("same target refresh does not ask WindowServer to reorder again")
    func sameTargetRefreshDoesNotReorderAgain() {
        var state = ActiveAppUseIndicatorOrderingState()

        let initialOrder = state.shouldOrderAbove(windowId: 202, layer: 0, panelIsVisible: false)
        let sameTargetOrder = state.shouldOrderAbove(windowId: 202, layer: 0, panelIsVisible: true)
        let changedLayerOrder = state.shouldOrderAbove(windowId: 202, layer: 3, panelIsVisible: true)
        let changedTargetOrder = state.shouldOrderAbove(windowId: 303, layer: 3, panelIsVisible: true)

        #expect(initialOrder)
        #expect(!sameTargetOrder)
        #expect(changedLayerOrder)
        #expect(changedTargetOrder)

        state.reset()
        let afterResetOrder = state.shouldOrderAbove(windowId: 303, layer: 3, panelIsVisible: true)
        #expect(afterResetOrder)
    }

}
