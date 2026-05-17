import AOSComputerUseKit
import CoreGraphics
import Darwin
import Foundation

public struct CoorTestTargetState: Sendable, Equatable, Codable {
    public let pid: pid_t
    public let windowId: CGWindowID
    public let eventLogPath: String

    public init(pid: pid_t, windowId: CGWindowID, eventLogPath: String) {
        self.pid = pid
        self.windowId = windowId
        self.eventLogPath = eventLogPath
    }
}

public protocol CoorTestTargetClient: Sendable {
    func open() async throws -> CoorTestTargetState
}

public struct LiveCoorTestTargetClient: CoorTestTargetClient {
    private let stateURL: URL
    private let eventLogURL: URL
    private let core: ComputerUseCoreClient

    public init(core: ComputerUseCoreClient) {
        let runDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aos", isDirectory: true)
            .appendingPathComponent("run", isDirectory: true)
        self.stateURL = runDir.appendingPathComponent("coordinate-target.json")
        self.eventLogURL = runDir.appendingPathComponent("coordinate-target-events.jsonl")
        self.core = core
    }

    public func open() async throws -> CoorTestTargetState {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: eventLogURL, options: .atomic)

        let executableURL = try targetExecutableURL()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--events", eventLogURL.path]
        try process.run()

        let pid = process.processIdentifier
        let window = try await waitForWindow(pid: pid)
        let state = CoorTestTargetState(
            pid: pid,
            windowId: window.id,
            eventLogPath: eventLogURL.path
        )
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        return state
    }

    private func targetExecutableURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["AOS_COORDINATE_TARGET_PATH"],
           !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw CoorTestTargetError("AOS_COORDINATE_TARGET_PATH is not executable: \(url.path)")
            }
            return url
        }

        guard let cliURL = Bundle.main.executableURL else {
            throw CoorTestTargetError("cannot resolve AOSComputerUseCLI executable path")
        }
        let url = cliURL.deletingLastPathComponent().appendingPathComponent("AOSCoordinateTarget")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw CoorTestTargetError("coordinate target executable not found at \(url.path); run swift build")
        }
        return url
    }

    private func waitForWindow(pid: pid_t) async throws -> WindowInfo {
        try await CoordinateTargetWindowWaiter.waitForWindow(
            pid: pid,
            attempts: 80,
            pollDelayNanoseconds: 25_000_000,
            windowsForPIDLookup: { pid in
                WindowServerWindowLookup.appWindows(forPid: pid)
            },
            sleep: { delay in
                try await Task.sleep(nanoseconds: delay)
            }
        )
    }
}

enum CoordinateTargetWindowWaiter {
    static func waitForWindow(
        pid: pid_t,
        attempts: Int,
        pollDelayNanoseconds: UInt64,
        windowsForPIDLookup: @Sendable (pid_t) -> [WindowInfo],
        sleep: @Sendable (UInt64) async throws -> Void
    ) async throws -> WindowInfo {
        for _ in 0..<attempts {
            if let window = windowsForPIDLookup(pid)
                .filter({ $0.isOnScreen && $0.layer == 0 })
                .max(by: { $0.zIndex < $1.zIndex }) {
                return window
            }
            try await sleep(pollDelayNanoseconds)
        }
        throw CoorTestTargetError("coordinate target pid \(pid) did not publish an on-screen window")
    }
}

private struct CoorTestTargetError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }

    init(_ message: String) {
        self.message = message
    }
}
