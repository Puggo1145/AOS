import Foundation
import AppKit
import AOSOSSenseKit
import AOSComputerUseKit

// MARK: - ComputerUseDoctorService
//
// Observable wrapper around `ComputerUseService.doctor` for the Shell side.
// Two consumers today:
//
//   1. Dev Mode panel — renders the latest report as a checklist and offers a
//      "Re-run" button so the developer can re-probe after toggling Privacy
//      settings without restarting the app.
//   2. Boot path — runs `refresh()` once after `permissionsService.allGranted`
//      flips true, so a SkyLight SPI miss or stale TCC grant is recorded
//      (and logged to stderr) before the agent ever issues a `computer_use_*`
//      tool call. Plan Stage 5: "权限或 SPI 缺失直接给用户反馈而不是 tool 失败".
//
// We don't drive UI banners directly — that's the Dev Mode panel's job.
// Surfacing failures into the notch UI is out of scope for the foundational
// pass; a stderr log + Dev Mode read-out is the minimum viable feedback loop.

@MainActor
@Observable
public final class ComputerUseDoctorService {
    public private(set) var lastReport: DoctorReport?
    public private(set) var lastRefreshedAt: Date?
    /// True while a refresh is in flight. Drives the Dev Mode button's
    /// spinner / disabled state without a separate state field.
    public private(set) var isRefreshing: Bool = false

    private let service: ComputerUseService
    private let permissions: PermissionsService

    /// Tracks whether we've already auto-run after the first all-granted
    /// transition so a flaky permission flip-flop doesn't spam the log.
    private var didAutoRun: Bool = false

    public init(service: ComputerUseService, permissions: PermissionsService) {
        self.service = service
        self.permissions = permissions
    }

    /// One-shot probe + cache. Reads Screen Recording state from the
    /// PermissionsService so we don't dual-probe TCC — the service already
    /// owns that policy (live SC probe vs. preflight cache).
    public func refresh() async {
        isRefreshing = true
        // PermissionsService tracks denied permissions explicitly; "granted"
        // is the complement. ScreenRecording is the live SC probe we trust.
        let granted = !permissions.state.denied.contains(.screenRecording)
        let report = await service.doctor(screenRecordingGranted: granted)
        lastReport = report
        lastRefreshedAt = Date()
        isRefreshing = false
        if let warning = Self.warningSummary(report) {
            // Stderr is the user-visible boot log channel — Stage 5's
            // "提前反馈" hook lands here before any agent tool call runs.
            FileHandle.standardError.write(
                Data("[shell] computer-use doctor: \(warning)\n".utf8)
            )
        }
    }

    /// Idempotent boot-time auto-probe. Caller drives this from a SwiftUI
    /// `.task` / `.onChange` so the run happens after permissions reach
    /// their settled state. Subsequent calls are no-ops; use `refresh()`
    /// for the explicit Dev Mode "Re-run" button.
    public func runOnceIfNeeded() async {
        guard !didAutoRun else { return }
        didAutoRun = true
        await refresh()
    }

    /// Compose a one-line warning if any required component is missing.
    /// `nil` when everything checks out — we don't log a noisy "all good"
    /// line because the report is already inspectable in Dev Mode.
    private static func warningSummary(_ r: DoctorReport) -> String? {
        var missing: [String] = []
        if !r.accessibility { missing.append("accessibility") }
        if !r.screenRecording { missing.append("screenRecording") }
        if !r.skyLightSPI.postToPid { missing.append("SLEventPostToPid") }
        if !r.skyLightSPI.authMessage { missing.append("authMessage") }
        if !r.skyLightSPI.focusWithoutRaise { missing.append("focusWithoutRaise") }
        if !r.skyLightSPI.windowLocation { missing.append("windowLocation") }
        if !r.skyLightSPI.spaces { missing.append("spaces") }
        return missing.isEmpty ? nil : "missing: \(missing.joined(separator: ", "))"
    }
}
