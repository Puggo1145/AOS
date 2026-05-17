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
}
