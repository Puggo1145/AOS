import Foundation
import os

// MARK: - SidecarProcess
//
// Owns the Bun child-process lifecycle. Per the plan §C / agents-md spec:
//   - executable: `bun`, resolved via PATH lookup with /opt/homebrew and
//     /usr/local fallbacks
//   - args: `run <resources>/sidecar/src/index.ts`
//     Resource path resolution works in two modes:
//       1. Bundled .app: `Bundle.main.resourceURL/sidecar`
//       2. `swift run`: `<repo-root>/sidecar` (resolved relative to the
//          executable URL by walking up out of `.build/...`)
//   - stderr: line-buffered → forwarded to Shell stderr with a `[sidecar]` tag
//   - unexpected exit: emit a callback so the Shell can enter a fatal boot/
//     runtime state instead of leaving the Notch UI connected to a dead pipe
//   - terminate(): SIGTERM, then force kill 1s later if still alive

public struct SidecarPipes {
    public let toSidecar: FileHandle  // Shell writes → Bun stdin
    public let fromSidecar: FileHandle // Shell reads ← Bun stdout

    public init(toSidecar: FileHandle, fromSidecar: FileHandle) {
        self.toSidecar = toSidecar
        self.fromSidecar = fromSidecar
    }
}

public enum SidecarLaunchError: Error {
    case bunNotFound
    case sidecarSourceNotFound(searched: [String])
    case launchFailed(underlying: Error)
}

public final class SidecarProcess: @unchecked Sendable {
    private var process: Process?
    private var stderrReadTask: Task<Void, Never>?
    private(set) public var pipes: SidecarPipes?
    private struct TerminationState {
        var expectedTermination: Bool = false
        var unexpectedExitHandler: (@Sendable (Int32) -> Void)?
    }
    private let terminationState = OSAllocatedUnfairLock<TerminationState>(
        initialState: TerminationState()
    )

    public init() {}

    public func setUnexpectedExitHandler(_ handler: @escaping @Sendable (Int32) -> Void) {
        terminationState.withLock { $0.unexpectedExitHandler = handler }
    }

    /// Spawn the Bun sidecar. Returns the stdio pipes so callers (RPCClient)
    /// can immediately attach.
    public func spawn() throws -> SidecarPipes {
        let bun = try Self.resolveBunBinary()
        let scriptPath = try Self.resolveSidecarScript()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bun)
        proc.arguments = ["run", scriptPath]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        do {
            try proc.run()
        } catch {
            throw SidecarLaunchError.launchFailed(underlying: error)
        }
        terminationState.withLock { $0.expectedTermination = false }
        proc.terminationHandler = { [weak self] process in
            self?.handleTermination(status: process.terminationStatus)
        }
        process = proc

        // Forward stderr → Shell stderr line by line.
        stderrReadTask = Task.detached {
            let h = stderr.fileHandleForReading
            var buffer = Data()
            while true {
                let chunk: Data
                do { chunk = try h.read(upToCount: 4096) ?? Data() } catch { break }
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<nl)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if let text = String(data: line, encoding: .utf8) {
                        FileHandle.standardError.write(
                            Data("[sidecar] \(text)\n".utf8)
                        )
                    }
                }
            }
        }

        let pipes = SidecarPipes(
            toSidecar: stdin.fileHandleForWriting,
            fromSidecar: stdout.fileHandleForReading
        )
        self.pipes = pipes
        return pipes
    }

    /// Graceful shutdown: SIGTERM, escalate to forceful terminate after 1s.
    public func terminate() {
        guard let proc = process, proc.isRunning else { return }
        terminationState.withLock { $0.expectedTermination = true }
        // Capture the pid up-front. Without this, between the
        // `proc.isRunning` check and `kill(...)` the OS could reuse this
        // pid for another process (rare but possible on macOS), and we'd
        // SIGKILL an unrelated process. The captured pid is also the only
        // identifier that survives `process` being reassigned by a future
        // respawn before the timer fires.
        let pid = proc.processIdentifier
        proc.terminate() // SIGTERM
        Task.detached {
            try? await Task.sleep(for: .seconds(1))
            if proc.isRunning && proc.processIdentifier == pid {
                kill(pid, SIGKILL)
            }
        }
    }

    /// Block until the sidecar exits. Used in tests.
    public func waitUntilExit() {
        process?.waitUntilExit()
    }

    public var isRunning: Bool { process?.isRunning ?? false }

    private func handleTermination(status: Int32) {
        let handler = terminationState.withLock { state -> (@Sendable (Int32) -> Void)? in
            state.expectedTermination ? nil : state.unexpectedExitHandler
        }
        handler?(status)
    }

    // MARK: - Resolution

    /// Find a usable `bun` binary. Resolution order:
    ///   1. Bundled binary at `Resources/sidecar/bin/bun` — set by
    ///      `Scripts/build-app.sh` so a packaged .app is self-contained
    ///      and doesn't depend on the user having Homebrew.
    ///   2. PATH lookup via `which bun` — covers `swift run` development.
    ///   3. Known Homebrew install locations on Apple Silicon and Intel.
    public static func resolveBunBinary() throws -> String {
        if let bundled = bundledBun() { return bundled }
        if let pathBun = whichBun() { return pathBun }
        let candidates = ["/opt/homebrew/bin/bun", "/usr/local/bin/bun"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        throw SidecarLaunchError.bunNotFound
    }

    private static func bundledBun() -> String? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let candidate = res.appendingPathComponent("sidecar/bin/bun").path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    private static func whichBun() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["which", "bun"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let line = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return line.isEmpty ? nil : line
    }

    /// Resolve the absolute path to `sidecar/src/index.ts`. The Shell runs in
    /// two real configurations:
    ///   - As an `.app`: `Bundle.main.resourceURL` is `Contents/Resources` and
    ///     Scripts/build-app.sh has copied the entire `sidecar/` tree there.
    ///   - As `swift run AOSShell`: the executable lives somewhere under
    ///     `.build/...`; the repo root holding `sidecar/` can be located by
    ///     walking up until a `Package.swift` is found.
    public static func resolveSidecarScript() throws -> String {
        var searched: [String] = []

        if let res = Bundle.main.resourceURL {
            let bundled = res.appendingPathComponent("sidecar/src/index.ts")
            searched.append(bundled.path)
            if FileManager.default.fileExists(atPath: bundled.path) {
                return bundled.path
            }
        }

        // Walk upward from the running executable looking for Package.swift.
        let exec = URL(fileURLWithPath: ProcessInfo.processInfo.arguments.first ?? "")
            .standardizedFileURL
        var dir = exec.deletingLastPathComponent()
        for _ in 0..<10 {
            let pkg = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: pkg.path) {
                let candidate = dir.appendingPathComponent("sidecar/src/index.ts")
                searched.append(candidate.path)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate.path
                }
            }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }

        // CWD fallback (e.g. `swift run` from repo root before sidecar/index.ts exists).
        let cwd = FileManager.default.currentDirectoryPath
        let cwdCandidate = (cwd as NSString).appendingPathComponent("sidecar/src/index.ts")
        searched.append(cwdCandidate)
        if FileManager.default.fileExists(atPath: cwdCandidate) {
            return cwdCandidate
        }

        throw SidecarLaunchError.sidecarSourceNotFound(searched: searched)
    }
}
