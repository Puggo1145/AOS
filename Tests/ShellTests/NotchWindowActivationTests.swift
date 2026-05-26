import AppKit
import Testing
@testable import Shell

@MainActor
@Suite("Notch window activation")
struct NotchWindowActivationTests {
    @Test("notch window accepts interaction without activating Notch Agent")
    func windowIsNonActivatingPanel() {
        let window = NotchWindow(
            contentRect: CGRect(x: 0, y: 0, width: 500, height: 240),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }

        #expect(window.styleMask.contains(.nonactivatingPanel))
        #expect(window.isFloatingPanel)
        #expect(window.hidesOnDeactivate == false)
        #expect(window.becomesKeyOnlyIfNeeded)
        #expect(window.canBecomeKey)
        #expect(window.canBecomeMain == false)
    }

    @Test("composer text view consumes the first click while the notch panel is inactive")
    func composerTextViewAcceptsFirstMouse() {
        let textView = _ChipTextView()

        #expect(textView.acceptsFirstMouse(for: nil))
    }

    @Test("system modal suppression hides visible notch window until outer modal ends")
    func systemModalSuppressionHidesVisibleWindowUntilOuterModalEnds() {
        let window = NotchWindow(
            contentRect: CGRect(x: 0, y: 0, width: 500, height: 240),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }

        window.ignoresMouseEvents = false
        window.orderFrontRegardless()
        #expect(window.isVisible)

        var state = NotchWindowController.ModalOverlaySuppressionState()
        NotchWindowController.beginSystemModalSuppression(window: window, state: &state)

        #expect(state.depth == 1)
        #expect(state.wasVisibleBeforeFirstModal)
        #expect(state.isActive)
        #expect(window.ignoresMouseEvents)
        #expect(!window.isVisible)

        NotchWindowController.beginSystemModalSuppression(window: window, state: &state)
        #expect(state.depth == 2)

        let restoredBeforeOuterEnd = NotchWindowController.endSystemModalSuppression(
            window: window,
            state: &state
        )
        #expect(!restoredBeforeOuterEnd)
        #expect(state.isActive)
        #expect(!window.isVisible)

        let restoredAfterOuterEnd = NotchWindowController.endSystemModalSuppression(
            window: window,
            state: &state
        )
        #expect(restoredAfterOuterEnd)
        #expect(!state.isActive)
        #expect(!state.wasVisibleBeforeFirstModal)
        #expect(window.isVisible)
    }

    @Test("system modal suppression keeps previously hidden notch window hidden")
    func systemModalSuppressionDoesNotRestorePreviouslyHiddenWindow() {
        let window = NotchWindow(
            contentRect: CGRect(x: 0, y: 0, width: 500, height: 240),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }

        #expect(!window.isVisible)

        var state = NotchWindowController.ModalOverlaySuppressionState()
        NotchWindowController.beginSystemModalSuppression(window: window, state: &state)

        #expect(state.isActive)
        #expect(!state.wasVisibleBeforeFirstModal)
        #expect(window.ignoresMouseEvents)
        #expect(!window.isVisible)

        let restored = NotchWindowController.endSystemModalSuppression(
            window: window,
            state: &state
        )
        #expect(!restored)
        #expect(!state.isActive)
        #expect(!window.isVisible)
    }

    @Test("active system modal suppression carries across notch window replacement")
    func activeSystemModalSuppressionCarriesAcrossWindowReplacement() {
        let firstWindow = NotchWindow(
            contentRect: CGRect(x: 0, y: 0, width: 500, height: 240),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        firstWindow.orderFrontRegardless()

        var state = NotchWindowController.ModalOverlaySuppressionState()
        NotchWindowController.beginSystemModalSuppression(window: firstWindow, state: &state)
        firstWindow.close()

        let replacementWindow = NotchWindow(
            contentRect: CGRect(x: 0, y: 0, width: 500, height: 240),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        defer { replacementWindow.close() }

        replacementWindow.orderFrontRegardless()
        NotchWindowController.applyActiveSystemModalSuppression(
            window: replacementWindow,
            state: state
        )

        #expect(state.isActive)
        #expect(replacementWindow.ignoresMouseEvents)
        #expect(!replacementWindow.isVisible)

        let restored = NotchWindowController.endSystemModalSuppression(
            window: replacementWindow,
            state: &state
        )
        #expect(restored)
        #expect(!state.isActive)
        #expect(replacementWindow.isVisible)
    }
}
