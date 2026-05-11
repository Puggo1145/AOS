import AOSComputerUseKit
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

public enum ComputerUsePermission: String, Sendable, Hashable, CaseIterable {
    case accessibility
    case screenRecording

    var displayName: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        }
    }
}

public struct PermissionGrantResult: Sendable, Equatable {
    public let requested: [ComputerUsePermission]
    public let status: [ComputerUsePermission: Bool]
    public let guidance: [String]

    public init(
        requested: [ComputerUsePermission],
        status: [ComputerUsePermission: Bool],
        guidance: [String]
    ) {
        self.requested = requested
        self.status = status
        self.guidance = guidance
    }
}

public protocol ComputerUsePermissionClient: Sendable {
    func request(_ permissions: [ComputerUsePermission]) async throws -> PermissionGrantResult
}

public struct LiveComputerUsePermissionClient: ComputerUsePermissionClient {
    public init() {}

    public func request(_ permissions: [ComputerUsePermission]) async throws -> PermissionGrantResult {
        for permission in permissions {
            requestPrompt(for: permission)
            openSystemSettings(for: permission)
        }

        return PermissionGrantResult(
            requested: permissions,
            status: currentStatus(for: permissions),
            guidance: permissions.map(guidanceLine(for:))
        )
    }

    private func requestPrompt(for permission: ComputerUsePermission) {
        switch permission {
        case .accessibility:
            let options: NSDictionary = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true
            ]
            _ = AXIsProcessTrustedWithOptions(options)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        }
    }

    private func currentStatus(for permissions: [ComputerUsePermission]) -> [ComputerUsePermission: Bool] {
        Dictionary(uniqueKeysWithValues: permissions.map { permission in
            switch permission {
            case .accessibility:
                return (permission, AXIsProcessTrusted())
            case .screenRecording:
                return (permission, CGPreflightScreenCaptureAccess())
            }
        })
    }

    private func openSystemSettings(for permission: ComputerUsePermission) {
        let urlString: String
        switch permission {
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }

        guard let url = URL(string: urlString) else {
            preconditionFailure("invalid System Settings URL for \(permission.rawValue)")
        }
        NSWorkspace.shared.open(url)
    }

    private func guidanceLine(for permission: ComputerUsePermission) -> String {
        switch permission {
        case .accessibility:
            return "Grant Accessibility to the terminal app running AOSComputerUseCLI, then rerun the command."
        case .screenRecording:
            return "Grant Screen Recording to the terminal app running AOSComputerUseCLI; macOS may require restarting that terminal app."
        }
    }
}

public protocol ComputerUseCoreClient: Sendable {
    func listApps(mode: AppListMode) async throws -> [AppInfo]
    func listWindows(pid: pid_t) async throws -> [WindowInfo]
    func getAppState(
        pid: pid_t,
        windowId: CGWindowID,
        captureMode: CaptureMode,
        maxImageDimension: Int
    ) async throws -> AppStateBundle
    /// Focuses the pid/window pair without raising or reordering the window.
    func focusWindowWithoutRaise(pid: pid_t, windowId: CGWindowID) async throws -> WindowFocusResult
    /// Posts a left click to an explicit screen-space point in the pid/window pair.
    func postLeftClick(pid: pid_t, windowId: CGWindowID, point: CGPoint) async throws -> WindowClickResult
}

public struct ComputerUseCoreAdapter: ComputerUseCoreClient {
    private let core: ComputerUseCore

    public init(core: ComputerUseCore = ComputerUseCore()) {
        self.core = core
    }

    public func listApps(mode: AppListMode) async throws -> [AppInfo] {
        await core.listApps(mode: mode)
    }

    public func listWindows(pid: pid_t) async throws -> [WindowInfo] {
        await core.listWindows(pid: pid)
    }

    public func getAppState(
        pid: pid_t,
        windowId: CGWindowID,
        captureMode: CaptureMode,
        maxImageDimension: Int
    ) async throws -> AppStateBundle {
        try await core.getAppState(
            pid: pid,
            windowId: windowId,
            captureMode: captureMode,
            maxImageDimension: maxImageDimension
        )
    }

    public func focusWindowWithoutRaise(pid: pid_t, windowId: CGWindowID) async throws -> WindowFocusResult {
        try await core.focusWindowWithoutRaise(pid: pid, windowId: windowId)
    }

    public func postLeftClick(pid: pid_t, windowId: CGWindowID, point: CGPoint) async throws -> WindowClickResult {
        try await core.postLeftClick(pid: pid, windowId: windowId, point: point)
    }

}

public struct ComputerUseCLIResult: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

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

    public init() {
        let runDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aos", isDirectory: true)
            .appendingPathComponent("run", isDirectory: true)
        self.stateURL = runDir.appendingPathComponent("coordinate-target.json")
        self.eventLogURL = runDir.appendingPathComponent("coordinate-target-events.jsonl")
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
        for _ in 0..<80 {
            if let window = WindowEnumerator.appWindows(forPid: pid)
                .filter({ $0.isOnScreen })
                .max(by: { $0.zIndex < $1.zIndex }) {
                return window
            }
            try await Task.sleep(nanoseconds: 25_000_000)
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

public enum ComputerUseCLI {
    public static func helpText() throws -> String {
        """
        Usage:
          AOSComputerUseCLI --help
          AOSComputerUseCLI help
          AOSComputerUseCLI grant-permissions
          AOSComputerUseCLI open-coor-test
          AOSComputerUseCLI list-apps [--mode running|all]
          AOSComputerUseCLI list-windows --pid <pid>
          AOSComputerUseCLI get-app-state --pid <pid> --window-id <id> [--mode vision|ax] [--max-image-dimension <pixels>] [--screenshot-output <path>]
          AOSComputerUseCLI focus-window --pid <pid> --window-id <id>
          AOSComputerUseCLI post-left-click --pid <pid> --window-id <id> --coor <x,y>

        Options:
          --json          Emit machine-readable JSON instead of the default readable text.

        Commands:
          grant-permissions  Trigger macOS prompts and open System Settings for required permissions.
          open-coor-test  Open the coordinate click test target as a separate process.
          list-apps       List running apps by default, or all launchable apps with --mode all.
          list-windows    List layer-0 windows owned by a process id.
          get-app-state   Capture AX tree and/or screenshot for a specific app window.
          focus-window    Focus a specific app window without raising it.
          post-left-click
                          Post a background left click to a local --coor point of a specific app window.

        Output:
          Successful commands write readable text to stdout by default.
          Errors write a message to stderr and return non-zero.
        """
    }

    public static func run(
        arguments: [String],
        core: ComputerUseCoreClient,
        permissions: ComputerUsePermissionClient = LiveComputerUsePermissionClient(),
        coorTestTarget: CoorTestTargetClient = LiveCoorTestTargetClient()
    ) async throws -> ComputerUseCLIResult {
        do {
            let parsed = try ParsedCommand(arguments: arguments)
            switch parsed.command {
            case .help:
                return ComputerUseCLIResult(stdout: try helpText() + "\n", stderr: "", exitCode: 0)
            case .grantPermissions:
                let grant = try await permissions.request([.accessibility, .screenRecording])
                return try success(GrantPermissionsOutput(grant), format: parsed.outputFormat)
            case .openCoorTestTarget:
                let state = try await coorTestTarget.open()
                return try success(OpenCoorTestOutput(state: state), format: parsed.outputFormat)
            case .listApps(let mode):
                let apps = try await core.listApps(mode: mode)
                return try success(ListAppsOutput(mode: mode, apps: apps), format: parsed.outputFormat)
            case .listWindows(let pid):
                let windows = try await core.listWindows(pid: pid)
                return try success(ListWindowsOutput(pid: pid, windows: windows), format: parsed.outputFormat)
            case .getAppState(let request):
                let state = try await core.getAppState(
                    pid: request.pid,
                    windowId: request.windowId,
                    captureMode: request.captureMode,
                    maxImageDimension: request.maxImageDimension
                )
                if let outputPath = request.screenshotOutput,
                   let screenshot = state.screenshot {
                    try screenshot.imageData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
                }
                return try success(AppStateOutput(request: request, state: state), format: parsed.outputFormat)
            case .focusWindow(let request):
                let result = try await core.focusWindowWithoutRaise(
                    pid: request.pid,
                    windowId: request.windowId
                )
                return try success(FocusWindowOutput(request: request, result: result), format: parsed.outputFormat)
            case .postLeftClick(let request):
                let result = try await postLeftClick(request: request, core: core)
                return try success(LeftClickOutput(request: request, result: result), format: parsed.outputFormat)
            }
        } catch let error as UsageError {
            return ComputerUseCLIResult(stdout: "", stderr: error.message + "\n", exitCode: 64)
        } catch {
            return ComputerUseCLIResult(stdout: "", stderr: String(describing: error) + "\n", exitCode: 1)
        }
    }

    private static func success<T: Encodable & ReadableOutput>(
        _ payload: T,
        format: OutputFormat
    ) throws -> ComputerUseCLIResult {
        switch format {
        case .text:
            return ComputerUseCLIResult(stdout: payload.readableText + "\n", stderr: "", exitCode: 0)
        case .json:
            return try jsonSuccess(payload)
        }
    }

    private static func jsonSuccess<T: Encodable>(_ payload: T) throws -> ComputerUseCLIResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw UsageError("failed to encode JSON output as UTF-8")
        }
        return ComputerUseCLIResult(stdout: text + "\n", stderr: "", exitCode: 0)
    }

    private static func postLeftClick(
        request: LeftClickRequest,
        core: ComputerUseCoreClient
    ) async throws -> WindowClickResult {
        let windows = try await core.listWindows(pid: request.pid)
        guard let window = windows.first(where: { $0.id == request.windowId }) else {
            throw UsageError("window \(request.windowId) for pid \(request.pid) is not available")
        }
        let screenPoint = CGPoint(
            x: window.bounds.x + request.coordinate.x,
            y: window.bounds.y + request.coordinate.y
        )
        return try await core.postLeftClick(
            pid: request.pid,
            windowId: request.windowId,
            point: screenPoint
        )
    }

}

private struct ParsedCommand {
    let command: Command
    let outputFormat: OutputFormat

    enum Command {
        case help
        case grantPermissions
        case openCoorTestTarget
        case listApps(mode: AppListMode)
        case listWindows(pid: pid_t)
        case getAppState(AppStateRequest)
        case focusWindow(FocusWindowRequest)
        case postLeftClick(LeftClickRequest)
    }

    init(arguments: [String]) throws {
        guard let first = arguments.first else {
            command = .help
            outputFormat = .text
            return
        }

        if first == "--help" || first == "-h" || first == "help" {
            command = .help
            outputFormat = .text
            return
        }

        var options = OptionCursor(Array(arguments.dropFirst()))
        let outputFormat: OutputFormat = try options.takeFlag("--json") ? .json : .text
        switch first {
        case "grant-permissions":
            try options.rejectUnused()
            command = .grantPermissions
        case "open-coor-test":
            try options.rejectUnused()
            command = .openCoorTestTarget
        case "list-apps":
            let mode = try options.optionalEnum("--mode", AppListMode.self) ?? .running
            try options.rejectUnused()
            command = .listApps(mode: mode)
        case "list-windows":
            let pid = try options.requiredPID("--pid")
            try options.rejectUnused()
            command = .listWindows(pid: pid)
        case "get-app-state":
            let pid = try options.requiredPID("--pid")
            let windowId = try options.requiredWindowID("--window-id")
            let captureMode = try options.optionalEnum("--mode", CaptureMode.self) ?? .vision
            let maxImageDimension = try options.optionalInt("--max-image-dimension") ?? 0
            let screenshotOutput = try options.optionalString("--screenshot-output")
            try options.rejectUnused()
            command = .getAppState(AppStateRequest(
                pid: pid,
                windowId: windowId,
                captureMode: captureMode,
                maxImageDimension: maxImageDimension,
                screenshotOutput: screenshotOutput
            ))
        case "focus-window":
            let pid = try options.requiredPID("--pid")
            let windowId = try options.requiredWindowID("--window-id")
            try options.rejectUnused()
            command = .focusWindow(FocusWindowRequest(pid: pid, windowId: windowId))
        case "post-left-click":
            let pid = try options.requiredPID("--pid")
            let windowId = try options.requiredWindowID("--window-id")
            let coordinate = try options.requiredPoint("--coor")
            try options.rejectUnused()
            command = .postLeftClick(LeftClickRequest(pid: pid, windowId: windowId, coordinate: coordinate))
        default:
            throw UsageError("unknown command \(first). Run AOSComputerUseCLI --help")
        }
        self.outputFormat = outputFormat
    }
}

private enum OutputFormat {
    case text
    case json
}

private protocol ReadableOutput {
    var readableText: String { get }
}

private struct OptionCursor {
    private var args: [String]

    init(_ args: [String]) {
        self.args = args
    }

    mutating func requiredPID(_ name: String) throws -> pid_t {
        let value = try requiredString(name)
        guard let parsed = Int32(value), parsed > 0 else {
            throw UsageError("invalid value for \(name): \(value)")
        }
        return pid_t(parsed)
    }

    mutating func requiredWindowID(_ name: String) throws -> CGWindowID {
        let value = try requiredString(name)
        guard let parsed = UInt32(value) else {
            throw UsageError("invalid value for \(name): \(value)")
        }
        return CGWindowID(parsed)
    }

    mutating func optionalInt(_ name: String) throws -> Int? {
        guard let value = try takeValue(name) else { return nil }
        guard let parsed = Int(value), parsed >= 0 else {
            throw UsageError("invalid value for \(name): \(value)")
        }
        return parsed
    }

    mutating func optionalDouble(_ name: String) throws -> Double? {
        guard let value = try takeValue(name) else { return nil }
        guard let parsed = Double(value) else {
            throw UsageError("invalid value for \(name): \(value)")
        }
        return parsed
    }

    mutating func requiredPoint(_ name: String) throws -> CGPoint {
        let raw = try requiredString(name)
        return try parsePoint(raw, optionName: name)
    }

    mutating func optionalPoint(_ name: String) throws -> CGPoint? {
        guard let raw = try takeValue(name) else {
            return nil
        }
        return try parsePoint(raw, optionName: name)
    }

    private func parsePoint(_ raw: String, optionName: String) throws -> CGPoint {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        let parts = trimmed
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 2,
              let x = Double(parts[0]),
              let y = Double(parts[1]) else {
            throw UsageError("invalid value for \(optionName): \(raw); expected x,y")
        }
        return CGPoint(x: x, y: y)
    }

    mutating func optionalString(_ name: String) throws -> String? {
        try takeValue(name)
    }

    mutating func takeFlag(_ name: String) throws -> Bool {
        guard let index = args.firstIndex(of: name) else { return false }
        args.remove(at: index)
        return true
    }

    mutating func optionalEnum<T: RawRepresentable>(_ name: String, _ type: T.Type) throws -> T?
        where T.RawValue == String
    {
        guard let value = try takeValue(name) else { return nil }
        guard let parsed = T(rawValue: value) else {
            throw UsageError("invalid value for \(name): \(value)")
        }
        return parsed
    }

    mutating func rejectUnused() throws {
        if let first = args.first {
            throw UsageError("unknown option \(first)")
        }
    }

    private mutating func requiredString(_ name: String) throws -> String {
        guard let value = try takeValue(name) else {
            throw UsageError("missing required option \(name)")
        }
        return value
    }

    private mutating func takeValue(_ name: String) throws -> String? {
        guard let index = args.firstIndex(of: name) else { return nil }
        let valueIndex = args.index(after: index)
        guard valueIndex < args.endIndex else {
            throw UsageError("missing value for \(name)")
        }
        let value = args[valueIndex]
        args.remove(at: valueIndex)
        args.remove(at: index)
        return value
    }
}

private struct UsageError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }

    init(_ message: String) {
        self.message = message
    }
}

private struct AppStateRequest: Sendable {
    let pid: pid_t
    let windowId: CGWindowID
    let captureMode: CaptureMode
    let maxImageDimension: Int
    let screenshotOutput: String?
}

private struct FocusWindowRequest: Sendable {
    let pid: pid_t
    let windowId: CGWindowID
}

private struct LeftClickRequest: Sendable {
    let pid: pid_t
    let windowId: CGWindowID
    let coordinate: CGPoint
}

private struct GrantPermissionsOutput: Encodable, ReadableOutput {
    let command = "grant-permissions"
    let requested: [String]
    let status: [String: Bool]
    let guidance: [String]

    init(_ result: PermissionGrantResult) {
        self.requested = result.requested.map(\.rawValue)
        self.status = Dictionary(uniqueKeysWithValues: result.status.map { permission, granted in
            (permission.rawValue, granted)
        })
        self.guidance = result.guidance
    }

    var readableText: String {
        var lines = ["Permission Setup"]
        for permission in ComputerUsePermission.allCases where requested.contains(permission.rawValue) {
            let granted = status[permission.rawValue] == true
            lines.append("- \(permission.displayName): \(granted ? "granted" : "not granted")")
        }
        if !guidance.isEmpty {
            lines.append("")
            lines.append("Next steps:")
            lines.append(contentsOf: guidance.map { "- \($0)" })
        }
        return lines.joined(separator: "\n")
    }
}

private struct OpenCoorTestOutput: Encodable, ReadableOutput {
    let command = "open-coor-test"
    let pid: pid_t
    let windowId: CGWindowID
    let eventLogPath: String

    init(state: CoorTestTargetState) {
        self.pid = state.pid
        self.windowId = state.windowId
        self.eventLogPath = state.eventLogPath
    }

    var readableText: String {
        """
        Coordinate click test target opened
        - pid \(pid)
        - window \(windowId)
        - events \(eventLogPath)
        """
    }
}

private struct ListAppsOutput: Encodable, ReadableOutput {
    let command = "list-apps"
    let mode: String
    let apps: [AppInfoOutput]

    init(mode: AppListMode, apps: [AppInfo]) {
        self.mode = mode.rawValue
        self.apps = apps.map(AppInfoOutput.init)
    }

    var readableText: String {
        var lines = ["Apps (\(mode))"]
        if apps.isEmpty {
            lines.append("No apps found.")
            return lines.joined(separator: "\n")
        }
        lines.append(contentsOf: apps.map { app in
            let pid = app.pid.map { "pid \($0)" } ?? "not running"
            let active = app.active ? " active" : ""
            let bundle = app.bundleId.map { " \($0)" } ?? ""
            return "- \(app.name) (\(pid))\(active)\(bundle)"
        })
        return lines.joined(separator: "\n")
    }
}

private struct AppInfoOutput: Encodable {
    let pid: pid_t?
    let bundleId: String?
    let name: String
    let path: String?
    let running: Bool
    let active: Bool
    let identity: String

    init(_ app: AppInfo) {
        self.pid = app.pid
        self.bundleId = app.bundleId
        self.name = app.name
        self.path = app.path
        self.running = app.running
        self.active = app.active
        self.identity = app.identity
    }
}

private struct ListWindowsOutput: Encodable, ReadableOutput {
    let command = "list-windows"
    let pid: pid_t
    let windows: [WindowInfoOutput]

    init(pid: pid_t, windows: [WindowInfo]) {
        self.pid = pid
        self.windows = windows.map(WindowInfoOutput.init)
    }

    var readableText: String {
        var lines = ["Windows for pid \(pid)"]
        if windows.isEmpty {
            lines.append("No layer-0 windows found.")
            return lines.joined(separator: "\n")
        }
        lines.append(contentsOf: windows.map { window in
            let screen = window.isOnScreen ? "on-screen" : "off-screen"
            let title = window.title.isEmpty ? "(untitled)" : window.title
            return "- \(window.windowId) \(title) \(Int(window.bounds.width))x\(Int(window.bounds.height)) @ \(Int(window.bounds.x)),\(Int(window.bounds.y)) \(screen) z:\(window.zIndex)"
        })
        return lines.joined(separator: "\n")
    }
}

private struct WindowInfoOutput: Encodable {
    let windowId: CGWindowID
    let pid: pid_t
    let owner: String
    let title: String
    let bounds: BoundsOutput
    let zIndex: Int
    let isOnScreen: Bool
    let layer: Int

    init(_ window: WindowInfo) {
        self.windowId = window.id
        self.pid = window.pid
        self.owner = window.owner
        self.title = window.title
        self.bounds = BoundsOutput(window.bounds)
        self.zIndex = window.zIndex
        self.isOnScreen = window.isOnScreen
        self.layer = window.layer
    }
}

private struct AppStateOutput: Encodable, ReadableOutput {
    let command = "get-app-state"
    let pid: pid_t
    let windowId: CGWindowID
    let mode: String
    let maxImageDimension: Int
    let appName: String?
    let bundleId: String?
    let stateId: String
    let treeMarkdown: String
    let elementCount: Int
    let screenshot: ScreenshotOutput?

    init(request: AppStateRequest, state: AppStateBundle) {
        self.pid = request.pid
        self.windowId = request.windowId
        self.mode = request.captureMode.rawValue
        self.maxImageDimension = request.maxImageDimension
        self.appName = state.appName
        self.bundleId = state.bundleId
        self.stateId = state.stateId.raw
        self.treeMarkdown = state.treeMarkdown
        self.elementCount = state.elementCount
        self.screenshot = state.screenshot.map {
            ScreenshotOutput($0, outputPath: request.screenshotOutput)
        }
    }

    var readableText: String {
        var lines = ["App State"]
        let app = appName ?? bundleId ?? "pid \(pid)"
        lines.append("Target: \(app) pid \(pid), window \(windowId), mode \(mode)")
        lines.append("State ID: \(stateId)")
        lines.append("AX elements: \(elementCount)")
        if let screenshot {
            var shot = "Screenshot: \(screenshot.format) \(screenshot.width)x\(screenshot.height), \(screenshot.byteCount) bytes"
            if let outputPath = screenshot.outputPath {
                shot += ", saved to \(outputPath)"
            }
            lines.append(shot)
        } else {
            lines.append("Screenshot: not captured")
        }
        if !treeMarkdown.isEmpty {
            lines.append("")
            lines.append("AX Tree:")
            lines.append(treeMarkdown)
        }
        return lines.joined(separator: "\n")
    }
}

private struct FocusWindowOutput: Encodable, ReadableOutput {
    let command = "focus-window"
    let pid: pid_t
    let windowId: CGWindowID

    init(request _: FocusWindowRequest, result: WindowFocusResult) {
        self.pid = result.pid
        self.windowId = result.windowId
    }

    var readableText: String {
        "Focused window \(windowId) without raising it (pid \(pid))."
    }
}

private struct LeftClickOutput: Encodable, ReadableOutput {
    let command = "post-left-click"
    let pid: pid_t
    let windowId: CGWindowID
    let point: PointOutput

    init(request _: LeftClickRequest, result: WindowClickResult) {
        self.pid = result.pid
        self.windowId = result.windowId
        self.point = PointOutput(result.point)
    }

    var readableText: String {
        "Posted left click to window \(windowId) at \(Int(point.x)),\(Int(point.y)) (pid \(pid))."
    }
}

private struct PointOutput: Encodable {
    let x: Double
    let y: Double

    init(_ point: CGPoint) {
        self.x = point.x
        self.y = point.y
    }
}

private struct ScreenshotOutput: Encodable {
    let format: String
    let width: Int
    let height: Int
    let scaleFactor: Double
    let originalWidth: Int?
    let originalHeight: Int?
    let byteCount: Int
    let coordinateSpace: CoordinateSpaceOutput
    let outputPath: String?
    let base64: String?

    init(_ screenshot: Screenshot, outputPath: String?) {
        self.format = screenshot.format.rawValue
        self.width = screenshot.width
        self.height = screenshot.height
        self.scaleFactor = screenshot.scaleFactor
        self.originalWidth = screenshot.originalWidth
        self.originalHeight = screenshot.originalHeight
        self.byteCount = screenshot.imageData.count
        self.coordinateSpace = CoordinateSpaceOutput(screenshot.coordinateSpace)
        self.outputPath = outputPath
        self.base64 = outputPath == nil ? screenshot.imageData.base64EncodedString() : nil
    }
}

private struct CoordinateSpaceOutput: Encodable {
    let windowFrame: BoundsOutput
    let windowBounds: BoundsOutput
    let pixelSize: PixelSizeOutput

    init(_ coordinateSpace: ScreenshotCoordinateSpace) {
        self.windowFrame = BoundsOutput(coordinateSpace.windowFrame)
        self.windowBounds = BoundsOutput(coordinateSpace.windowBounds)
        self.pixelSize = PixelSizeOutput(coordinateSpace.pixelSize)
    }
}

private struct BoundsOutput: Encodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ bounds: WindowBounds) {
        self.x = bounds.x
        self.y = bounds.y
        self.width = bounds.width
        self.height = bounds.height
    }
}

private struct PixelSizeOutput: Encodable {
    let width: Double
    let height: Double

    init(_ size: CGSize) {
        self.width = size.width
        self.height = size.height
    }
}
