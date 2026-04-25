import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

// MARK: - PermissionsService
//
// Per `docs/designs/os-sense.md` §"权限". Shell-level single source of
// truth for runtime permissions consumed by OS Sense (and Computer Use).
// All probing + system-prompt requests are centralized here; subsystems
// read the published `state` and call `request(_:)` for the user-facing
// flow. Subsystems never run their own probes.
//
// Probe APIs:
//   - Accessibility:    `AXIsProcessTrusted()`              (sync, live)
//   - Screen Recording: `SCShareableContent.current`        (async, live)
//                       — `CGPreflightScreenCaptureAccess()` is
//                       documented to *cache for the process lifetime*
//                       (see Apple's Core Graphics docs). Granting via
//                       System Settings would never propagate into a
//                       running poll loop. `SCShareableContent` queries
//                       TCC fresh on every call; that's why Apple's
//                       own "Quit & Reopen" prompt exists *for apps
//                       that don't query the live API*.
//   - Automation:       NOT probed (no caller). Schema slot is preserved.
//
// Request APIs (used by the onboard permission panel):
//   - Accessibility:    `AXIsProcessTrustedWithOptions(prompt: true)`
//   - Screen Recording: `CGRequestScreenCaptureAccess()`
// Both fire a system prompt the first time and are no-ops after the
// user has answered. We always *also* open System Settings to the
// matching Privacy pane, which covers the common case where TCC has a
// stale-denied record (no fresh prompt) and the user must flip the
// toggle by hand.

@MainActor
@Observable
public final class PermissionsService {
    public private(set) var state: PermissionState = PermissionState(denied: [])

    /// Whether `SCShareableContent.current` is safe to call as a
    /// non-prompting live probe. SC throws/returns based on TCC, BUT
    /// the very first call in a process when *no TCC record exists*
    /// triggers the system permission alert. So we gate the live probe
    /// behind "we know a record exists":
    ///   - true at init iff `CGPreflightScreenCaptureAccess()` says
    ///     granted (a granted state implies a record is on file)
    ///   - flipped true the moment the user clicks Grant Access
    ///     (`CGRequestScreenCaptureAccess()` creates a record either
    ///     way — granted, denied, or pending user response)
    /// Until safe, `refresh()` uses CGPreflight, which is documented
    /// to cache for the process lifetime but at least never prompts.
    private var screenRecordingProbeIsSafe: Bool = false

    public init() {
        // Pre-arm the live probe if we already know a TCC record
        // exists (i.e. permission was previously granted). Avoids
        // forcing the user to click Grant Access just so post-grant
        // revoke→regrant becomes detectable mid-session.
        if CGPreflightScreenCaptureAccess() {
            screenRecordingProbeIsSafe = true
        }
    }

    /// Re-probe permissions and publish the resulting state. Async
    /// because the authoritative Screen Recording probe is async —
    /// see `screenRecordingProbeIsSafe` for why we don't always go
    /// straight to SCShareableContent.
    public func refresh() async {
        let axTrusted = AXIsProcessTrusted()
        let screenRecordingGranted: Bool
        if screenRecordingProbeIsSafe {
            screenRecordingGranted = await probeScreenRecordingLive()
        } else {
            // Pre-Grant phase: never-asked-before. Use the
            // non-prompting probe; we'll switch to the live probe
            // after `request(.screenRecording)` creates a record.
            screenRecordingGranted = CGPreflightScreenCaptureAccess()
        }
        state = PermissionState(
            denied: Self.computeDeniedSet(
                axTrusted: axTrusted,
                screenRecordingGranted: screenRecordingGranted
            )
        )
    }

    /// Live screen-recording probe. Queries TCC fresh on every call,
    /// so toggling the permission in System Settings is reflected on
    /// the next poll tick. ONLY safe to call after we know a TCC
    /// record exists for this app — see `screenRecordingProbeIsSafe`.
    private func probeScreenRecordingLive() async -> Bool {
        do {
            _ = try await SCShareableContent.current
            return true
        } catch {
            return false
        }
    }

    /// True iff every probed permission is granted. `automation` is not
    /// probed yet so it does not gate this flag.
    public var allGranted: Bool { state.denied.isEmpty }

    /// Trigger the macOS system prompt for `permission` AND open the
    /// matching Privacy pane in System Settings. The dual-trigger
    /// matches the pattern used by `playground/open-codex-computer-use`:
    /// the system prompt fires the first time only, so opening Settings
    /// is the reliable path when the user has a stale-denied record.
    public func request(_ permission: Permission) {
        switch permission {
        case .accessibility:
            let options: NSDictionary = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true
            ]
            _ = AXIsProcessTrustedWithOptions(options)
        case .screenRecording:
            // Always creates a TCC record (granted / denied / pending),
            // so subsequent `SCShareableContent.current` calls won't
            // re-prompt for never-asked-before. Flip the guard so the
            // poll loop switches to the live probe.
            _ = CGRequestScreenCaptureAccess()
            screenRecordingProbeIsSafe = true
        case .automation:
            break
        }
        openSystemSettings(for: permission)
    }

    public func openSystemSettings(for permission: Permission) {
        let urlString: String
        switch permission {
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .automation:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Pure projection used by `refresh()` and unit tests.
    internal nonisolated static func computeDeniedSet(
        axTrusted: Bool,
        screenRecordingGranted: Bool
    ) -> Set<Permission> {
        var denied: Set<Permission> = []
        if !axTrusted { denied.insert(.accessibility) }
        if !screenRecordingGranted { denied.insert(.screenRecording) }
        return denied
    }
}
