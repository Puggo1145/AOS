import ApplicationServices
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

// MARK: - Permissions
//
// Per `docs/designs/computer-use.md` §"权限". The Shell hosts a single
// `PermissionsService` (see `AOSOSSenseKit.PermissionsService`) that owns
// runtime probing for OS Sense + Computer Use + the onboard UI. This
// file exposes the Kit-side projections needed by `computerUse.doctor`:
//
//   - `accessibility:bool`     — `AXIsProcessTrusted()`
//   - `screenRecording:bool`   — handed in by the Shell (live SC probe)
//   - `automation:bool`        — not used by Computer Use, kept for the
//                                wire schema
//   - `skyLightSPI`            — projection of `SkyLightEventPost.availability`
//
// `doctor` doesn't probe — it reads the cached state. Re-probing is the
// `PermissionsService`'s job (Shell-level, polled when the user returns
// from System Settings).

public struct DoctorReport: Sendable, Equatable {
    public let accessibility: Bool
    public let screenRecording: Bool
    public let automation: Bool
    public let skyLightSPI: SkyLightSPIStatus

    public init(
        accessibility: Bool,
        screenRecording: Bool,
        automation: Bool,
        skyLightSPI: SkyLightSPIStatus
    ) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.automation = automation
        self.skyLightSPI = skyLightSPI
    }
}

public struct SkyLightSPIStatus: Sendable, Equatable {
    public let postToPid: Bool
    public let authMessage: Bool
    public let focusWithoutRaise: Bool
    public let windowLocation: Bool
    public let spaces: Bool
    /// `_AXUIElementGetWindow` resolution (lives in `AOSAXSupport`).
    /// True iff the SPI returns a window id for an `AXWindow` element.
    /// We can't probe in isolation without an actual window handle, so
    /// the wire field assumes resolution succeeds when the symbol is
    /// linkable — which it always is on supported macOS.
    public let getWindow: Bool

    public init(
        postToPid: Bool,
        authMessage: Bool,
        focusWithoutRaise: Bool,
        windowLocation: Bool,
        spaces: Bool,
        getWindow: Bool
    ) {
        self.postToPid = postToPid
        self.authMessage = authMessage
        self.focusWithoutRaise = focusWithoutRaise
        self.windowLocation = windowLocation
        self.spaces = spaces
        self.getWindow = getWindow
    }
}

public enum Permissions {
    /// Live `AXIsProcessTrusted()` — the public Accessibility probe.
    /// Cheap (no IPC); safe to call on every `doctor` request.
    public static var accessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Build a `DoctorReport` from the live AX state + caller-supplied
    /// Screen Recording state. The Shell passes `screenRecordingGranted`
    /// from its `PermissionsService` so we don't dual-probe (and the
    /// Shell is the policy owner for whether to use the live or
    /// preflight probe).
    public static func report(screenRecordingGranted: Bool) -> DoctorReport {
        let availability = SkyLightEventPost.availability
        return DoctorReport(
            accessibility: accessibilityTrusted,
            screenRecording: screenRecordingGranted,
            automation: false,  // Computer Use doesn't depend on Automation
            skyLightSPI: SkyLightSPIStatus(
                postToPid: availability.postToPid,
                authMessage: availability.authMessage,
                focusWithoutRaise: availability.focusWithoutRaise,
                windowLocation: availability.windowLocation,
                spaces: availability.spaces,
                getWindow: true
            )
        )
    }
}
