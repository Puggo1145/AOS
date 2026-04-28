import AppKit
import CoreGraphics
import Foundation

// MARK: - AppEnumerator
//
// Backs `computerUse.listApps`. Returns the set of operable on-screen
// apps — `NSApplicationActivationPolicyRegular` only (filters out
// background helpers / agent processes the user would never want to
// drive).
//
// Derived primarily from `CGWindowListCopyWindowInfo` because
// `NSWorkspace.runningApplications`'s cache only refreshes when the
// main run-loop spins; in the Shell parent that's true, but to keep
// the signal current under task pressure we cross-check both sources.

public enum AppEnumerator {
    public static func operableApps() -> [AppInfo] {
        var seenPids = Set<pid_t>()
        var entries: [AppInfo] = []

        // Primary: pids that own a CGWindow right now. Always live —
        // every CGWindowList query hits WindowServer.
        if let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
            for window in windows {
                guard let rawPid = window[kCGWindowOwnerPID as String] as? Int,
                      let pid = pid_t(exactly: rawPid),
                      !seenPids.contains(pid),
                      let app = NSRunningApplication(processIdentifier: pid),
                      app.activationPolicy == .regular
                else { continue }
                seenPids.insert(pid)
                entries.append(makeInfo(app))
            }
        }

        // Secondary: regular-policy apps the workspace knows about that
        // haven't produced a window yet (rare, but possible during launch).
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let pid = app.processIdentifier
            if seenPids.contains(pid) { continue }
            seenPids.insert(pid)
            entries.append(makeInfo(app))
        }

        return entries
    }

    private static func makeInfo(_ app: NSRunningApplication) -> AppInfo {
        AppInfo(
            pid: app.processIdentifier,
            bundleId: app.bundleIdentifier,
            name: app.localizedName ?? "",
            active: app.isActive
        )
    }
}
