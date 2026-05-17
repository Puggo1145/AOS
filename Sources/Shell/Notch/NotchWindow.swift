import AppKit

// MARK: - NotchWindow
//
// Per notch-dev-guide.md §3.1. Subclassed NSWindow tuned for a transparent,
// always-on-top, all-Spaces overlay window. Required attributes:
//   - level above status bar so it sits over the menu bar
//   - collectionBehavior covers full-screen apps + Spaces switching
//   - non-activating panel semantics so mouse interaction doesn't deactivate
//     the user's current foreground app
//   - canBecomeKey = true so the prompt TextField receives keystrokes

final class NotchWindow: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        var panelStyle = style
        panelStyle.insert(.nonactivatingPanel)
        super.init(contentRect: contentRect, styleMask: panelStyle, backing: backing, defer: flag)
        configureForNotchOverlay()
    }

    private func configureForNotchOverlay() {
        isOpaque = false
        backgroundColor = .clear
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovable = false
        hasShadow = false
        ignoresMouseEvents = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 8)
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle
        ]
        // Without an explicit a11y label the borderless window is
        // announced as just "window" by VoiceOver. Naming the window and
        // tagging it as a floating-utility overlay lets AT distinguish
        // it from the user's actual document windows.
        setAccessibilityLabel("Notch Agent Notch")
        setAccessibilityRole(.window)
        setAccessibilitySubrole(.floatingWindow)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // LSUIElement + borderless windows have no app-supplied Edit menu, so the
    // system never wires Cmd-X/C/V/A/Z to the first responder. Without this
    // override paste silently no-ops inside the notch's TextField/SecureField.
    // Forward the standard editing shortcuts to the responder chain manually.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command else { return false }
        switch event.charactersIgnoringModifiers {
        case "x": return NSApp.sendAction(#selector(NSText.cut(_:)),       to: nil, from: self)
        case "c": return NSApp.sendAction(#selector(NSText.copy(_:)),      to: nil, from: self)
        case "v": return NSApp.sendAction(#selector(NSText.paste(_:)),     to: nil, from: self)
        case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
        case "z": return NSApp.sendAction(Selector(("undo:")),             to: nil, from: self)
        default:  return false
        }
    }
}
