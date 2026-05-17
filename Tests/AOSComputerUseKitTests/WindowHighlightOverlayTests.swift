@testable import AOSComputerUseKit
import AppKit
import CoreGraphics
import Testing

@Suite("Computer Use window highlight overlay")
struct WindowHighlightOverlayTests {
    @Test("layout draws glow around the true app window and keeps controls in their own frame")
    func layoutDrawsGlowAroundTrueWindowAndKeepsControlsInOwnFrame() {
        let windowRect = CGRect(x: 100, y: 200, width: 500, height: 300)
        let controlSize = CGSize(width: 184, height: 36)

        let layout = ComputerUseWindowHighlightLayout(
            windowRect: windowRect,
            glowOutset: 44,
            controlSize: controlSize
        )

        #expect(layout.glowFrame == CGRect(x: 56, y: 156, width: 588, height: 388))
        #expect(layout.windowFrameInGlow == CGRect(x: 44, y: 44, width: 500, height: 300))
        #expect(layout.controlFrame == CGRect(x: 258, y: 454, width: 184, height: 36))
    }

    @Test("control frame follows window movement without resizing")
    func controlFrameFollowsWindowMovementWithoutResizing() {
        let first = ComputerUseWindowHighlightLayout(
            windowRect: CGRect(x: 100, y: 200, width: 500, height: 300),
            glowOutset: 44,
            controlSize: CGSize(width: 184, height: 36)
        )
        let moved = ComputerUseWindowHighlightLayout(
            windowRect: CGRect(x: 170, y: 150, width: 500, height: 300),
            glowOutset: 44,
            controlSize: CGSize(width: 184, height: 36)
        )

        #expect(moved.controlFrame?.origin.x == (first.controlFrame?.origin.x ?? 0) + 70)
        #expect(moved.controlFrame?.origin.y == (first.controlFrame?.origin.y ?? 0) - 50)
        #expect(moved.controlFrame?.size == first.controlFrame?.size)
    }

    @Test("layout omits controls when no stop control is available")
    func layoutOmitsControlsWhenNoStopControlIsAvailable() {
        let layout = ComputerUseWindowHighlightLayout(
            windowRect: CGRect(x: 100, y: 200, width: 500, height: 300),
            glowOutset: 44,
            controlSize: nil
        )

        #expect(layout.controlFrame == nil)
    }

    @Test("panel roles make only the small controls panel interactive")
    @MainActor
    func panelRolesMakeOnlySmallControlsPanelInteractive() {
        let glowPanel = ComputerUseWindowHighlightPanel(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        glowPanel.configureForWindowHighlight(role: .glow)

        let controlPanel = ComputerUseWindowHighlightPanel(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        controlPanel.configureForWindowHighlight(role: .controls)

        #expect(glowPanel.ignoresMouseEvents)
        #expect(!controlPanel.ignoresMouseEvents)
        #expect(!glowPanel.canBecomeKey)
        #expect(!controlPanel.canBecomeMain)
    }
}
