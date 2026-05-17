import AppKit
import Foundation

// MARK: - main
//
// Entry point per notch-dev-guide.md §1.2 / §1.3:
//   - write pidfile to ~/.notch-agent/run/notch.pid; if a previous instance is alive,
//     terminate it before claiming the slot
//   - install a self-delete monitor on argv[0] so a binary swap during
//     development cleanly exits the old process
//   - set activation policy to .accessory (no Dock icon, can take key focus)
//   - run the AppDelegate

// Ensure the pidfile directory exists.
let pidFile = NotchPaths.pidFile
do {
    try FileManager.default.createDirectory(
        at: pidFile.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
} catch {
    FileHandle.standardError.write(
        Data("[shell] failed to create pidfile dir: \(error)\n".utf8)
    )
}

// Terminate any prior instance.
if let prev = try? String(contentsOf: pidFile, encoding: .utf8),
   let pid = Int(prev.trimmingCharacters(in: .whitespacesAndNewlines)),
   let app = NSRunningApplication(processIdentifier: pid_t(pid)),
   app.processIdentifier != NSRunningApplication.current.processIdentifier {
    app.terminate()
}

// Claim the slot.
let myPid = String(NSRunningApplication.current.processIdentifier)
do {
    try myPid.write(to: pidFile, atomically: true, encoding: .utf8)
} catch {
    FileHandle.standardError.write(
        Data("[shell] failed to write pidfile: \(error)\n".utf8)
    )
}

// Self-delete monitor: if argv[0] is unlinked (binary swap), exit cleanly.
if let executablePath = ProcessInfo.processInfo.arguments.first {
    let fd = open(executablePath, O_EVTONLY)
    if fd >= 0 {
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .delete,
            queue: DispatchQueue.global()
        )
        src.setEventHandler {
            if src.data.contains(.delete) {
                src.cancel()
                exit(0)
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        // Hold the source alive for the lifetime of the process.
        NotchPaths.retainSelfDeleteSource(src)
    }
}

// `NSApplication` is main-actor isolated. We're already on the main thread
// at process entry, but the compiler can't see that — assume isolation so
// the AppDelegate construction (also main-actor isolated) is allowed.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
