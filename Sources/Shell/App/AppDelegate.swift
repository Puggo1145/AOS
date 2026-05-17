import AppKit
import Foundation

// MARK: - AppDelegate
//
// Wires the macOS app lifecycle to CompositionRoot.
//   - `applicationDidFinishLaunching`: boot the comp root on @MainActor;
//     subscribe to didChangeScreenParameters to rebuild the notch window
//     when the display configuration changes; start a 1Hz pidfile-validation
//     timer per notch-dev-guide.md §1.2.
//   - `applicationWillTerminate`: shut the comp root down cleanly.

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let compositionRoot = CompositionRoot()
    private let pidFileURL: URL = NotchPaths.pidFile
    private var pidTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await compositionRoot.start() }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // 1Hz pidfile validation loop: terminate if some other Notch Agent instance
        // overwrote the pidfile.
        pidTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [pidFileURL] _ in
            let myPid = String(NSRunningApplication.current.processIdentifier)
            let onDisk = (try? String(contentsOf: pidFileURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if myPid.trimmingCharacters(in: .whitespacesAndNewlines) != onDisk {
                Task { @MainActor in NSApp.terminate(nil) }
            }
        }
    }

    @objc private func handleScreenChange() {
        Task { @MainActor in compositionRoot.rebuildWindow() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pidTimer?.invalidate()
        pidTimer = nil
        Task { @MainActor in compositionRoot.stop() }
    }
}
