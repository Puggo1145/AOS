import AppKit
import SwiftUI

// MARK: - Notification.Name
//
// Single notification fired by the Settings panel "Dev Mode" entry; the
// CompositionRoot subscribes and asks the controller to show the window.
// We use NotificationCenter rather than threading a callback all the way
// down through NotchView → SettingsPanelView so the dev surface stays
// fully optional — removing the subscriber removes the feature without
// touching the notch view tree.

public extension Notification.Name {
    static let aosOpenDevMode = Notification.Name("aos.dev.openDevMode")
}

// MARK: - DevModeWindowController
//
// Owns the standalone NSWindow that hosts the Dev Mode panel. The window is
// allocated lazily — `show()` either creates it on first call or brings the
// existing instance to front; the window is kept alive after close so future
// `show()` calls re-present without re-hydration.
//
// Why a separate window: Dev Mode is observational and out-of-band relative
// to the notch. Hosting it inside the notch panel would leak debug surfaces
// into the user-facing UI and force the notch's tight frame onto a view that
// wants a wide, scrollable raw payload.

@MainActor
public final class DevModeWindowController: NSObject, NSWindowDelegate {
    private let contextService: DevContextService
    private weak var sessionStore: SessionStore?
    private let doctorService: ComputerUseDoctorService?
    private var window: NSWindow?

    public init(
        contextService: DevContextService,
        sessionStore: SessionStore? = nil,
        doctorService: ComputerUseDoctorService? = nil
    ) {
        self.contextService = contextService
        self.sessionStore = sessionStore
        self.doctorService = doctorService
    }

    public func show() {
        if let win = window {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "AOS Dev Mode"
        win.isReleasedWhenClosed = false
        win.center()
        win.delegate = self
        win.contentView = NSHostingView(
            rootView: DevModePanelView(
                contextService: contextService,
                sessionStore: sessionStore,
                doctorService: doctorService
            )
        )
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func close() {
        window?.close()
    }

    public func windowWillClose(_ notification: Notification) {
        // Keep the controller alive — `show()` re-presents the existing window
        // without rebuilding the SwiftUI tree. The hosting view holds the
        // service reference so the notification subscription persists across
        // close/show cycles.
    }
}
