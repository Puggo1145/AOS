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
    func getAppType(pid: pid_t) async throws -> AppTypeResult
    func listWindows(pid: pid_t) async throws -> [WindowInfo]
    func getAppState(
        pid: pid_t,
        windowId: CGWindowID,
        captureMode: CaptureMode,
        maxImageDimension: Int
    ) async throws -> AppStateBundle
    /// Focuses the pid/window pair without raising or reordering the window.
    func focusWindowWithoutRaise(pid: pid_t, windowId: CGWindowID) async throws -> WindowFocusResult
    /// Posts a coordinate-based background mouse event in the pid/window pair.
    func postMouseEvent(
        pid: pid_t,
        windowId: CGWindowID,
        event: BackgroundMouseEvent
    ) async throws -> WindowMouseEventResult
    /// Posts a mouse event and returns diagnostic state captured around each event stage.
    func postMouseEventTrace(
        pid: pid_t,
        windowId: CGWindowID,
        event: BackgroundMouseEvent
    ) async throws -> WindowMouseEventTraceResult
    /// Posts a pid-scoped background keyboard event in the pid/window pair.
    func postKeyboardEvent(
        pid: pid_t,
        windowId: CGWindowID,
        event: BackgroundKeyboardEvent
    ) async throws -> WindowKeyboardEventResult
}

public enum PostCursorKey: Sendable, Equatable {
    case up
    case down
    case left
    case right
    case confirm
    case quit
}

public protocol PostCursorIO: Sendable {
    func write(_ text: String) async
    func readLine(prompt: String) async throws -> String
    func readKey() async throws -> PostCursorKey
}

public protocol PostCursorOverlay: Sendable {
    func show(at point: CGPoint) async throws
    func move(to point: CGPoint) async throws
    func hide() async
}

public struct WindowOrderObservationRequest: Sendable, Equatable {
    public let pid: pid_t
    public let windowId: CGWindowID
    public let durationMilliseconds: Int
    public let intervalMilliseconds: Int

    public init(
        pid: pid_t,
        windowId: CGWindowID,
        durationMilliseconds: Int,
        intervalMilliseconds: Int
    ) {
        self.pid = pid
        self.windowId = windowId
        self.durationMilliseconds = durationMilliseconds
        self.intervalMilliseconds = intervalMilliseconds
    }
}

public protocol WindowOrderObservationClient: Sendable {
    func observe(_ request: WindowOrderObservationRequest) async throws -> [WindowOrderObservationSample]
}

public enum MouseEventTapLocation: String, Sendable, Equatable, Encodable {
    case hid
    case session
    case annotated
    case all

    fileprivate var observedLocations: [MouseEventTapLocation] {
        switch self {
        case .hid, .session, .annotated:
            return [self]
        case .all:
            return [.hid, .session, .annotated]
        }
    }

    fileprivate var cgEventTapLocation: CGEventTapLocation {
        switch self {
        case .hid:
            return .cghidEventTap
        case .session:
            return .cgSessionEventTap
        case .annotated:
            return .cgAnnotatedSessionEventTap
        case .all:
            preconditionFailure("all is not a concrete CGEvent tap location")
        }
    }
}

public struct MouseEventObservationRequest: Sendable, Equatable {
    public let pid: pid_t?
    public let windowId: CGWindowID?
    public let durationMilliseconds: Int
    public let tapLocation: MouseEventTapLocation

    public init(
        pid: pid_t?,
        windowId: CGWindowID?,
        durationMilliseconds: Int,
        tapLocation: MouseEventTapLocation = .all
    ) {
        self.pid = pid
        self.windowId = windowId
        self.durationMilliseconds = durationMilliseconds
        self.tapLocation = tapLocation
    }
}

public struct MouseEventObservationSample: Sendable, Equatable, Encodable {
    public let tapLocation: MouseEventTapLocation
    public let elapsedNanoseconds: UInt64
    public let typeRawValue: UInt32
    public let typeName: String
    public let location: CGPoint
    public let sourcePID: pid_t
    public let targetPID: pid_t
    public let buttonNumber: Int64
    public let clickState: Int64
    public let subtype: Int64
    public let windowUnderMousePointer: Int64
    public let windowUnderMousePointerThatCanHandleThisEvent: Int64
    public let rawField0: Int64
    public let rawField40: Int64
    public let rawField51: Int64
    public let rawField58: Int64
    public let rawField91: Int64
    public let rawField92: Int64
    public let matchesRequestedTarget: Bool

    public init(
        tapLocation: MouseEventTapLocation,
        elapsedNanoseconds: UInt64,
        typeRawValue: UInt32,
        typeName: String,
        location: CGPoint,
        sourcePID: pid_t,
        targetPID: pid_t,
        buttonNumber: Int64,
        clickState: Int64,
        subtype: Int64,
        windowUnderMousePointer: Int64,
        windowUnderMousePointerThatCanHandleThisEvent: Int64,
        rawField0: Int64,
        rawField40: Int64,
        rawField51: Int64,
        rawField58: Int64,
        rawField91: Int64,
        rawField92: Int64,
        matchesRequestedTarget: Bool
    ) {
        self.tapLocation = tapLocation
        self.elapsedNanoseconds = elapsedNanoseconds
        self.typeRawValue = typeRawValue
        self.typeName = typeName
        self.location = location
        self.sourcePID = sourcePID
        self.targetPID = targetPID
        self.buttonNumber = buttonNumber
        self.clickState = clickState
        self.subtype = subtype
        self.windowUnderMousePointer = windowUnderMousePointer
        self.windowUnderMousePointerThatCanHandleThisEvent = windowUnderMousePointerThatCanHandleThisEvent
        self.rawField0 = rawField0
        self.rawField40 = rawField40
        self.rawField51 = rawField51
        self.rawField58 = rawField58
        self.rawField91 = rawField91
        self.rawField92 = rawField92
        self.matchesRequestedTarget = matchesRequestedTarget
    }
}

public protocol MouseEventObservationClient: Sendable {
    func observe(_ request: MouseEventObservationRequest) async throws -> [MouseEventObservationSample]
}

public struct LiveWindowOrderObservationClient: WindowOrderObservationClient {
    public init() {}

    public func observe(_ request: WindowOrderObservationRequest) async throws -> [WindowOrderObservationSample] {
        let probe = try WindowOrderProbe.live(targetPID: request.pid, targetWindowId: request.windowId)
        let durationNanoseconds = UInt64(request.durationMilliseconds) * 1_000_000
        let intervalNanoseconds = UInt64(request.intervalMilliseconds) * 1_000_000
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var samples: [WindowOrderObservationSample] = []

        while true {
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let elapsed = now >= start ? now - start : 0
            samples.append(probe.sample(elapsedNanoseconds: elapsed))
            if elapsed >= durationNanoseconds {
                return samples
            }
            try await Task.sleep(nanoseconds: intervalNanoseconds)
        }
    }
}

public struct LiveMouseEventObservationClient: MouseEventObservationClient {
    public init() {}

    public func observe(_ request: MouseEventObservationRequest) async throws -> [MouseEventObservationSample] {
        try MouseEventTapRecorder(request: request).observe()
    }
}

/// Listen-only mouse event tap used to compare AOS and Codex event stamps.
/// It deliberately records raw fields instead of interpreting them so browser
/// delivery diagnostics can fail loudly when the event path changes.
private final class MouseEventTapRecorder {
    private static let observedTypes: [CGEventType] = [
        .leftMouseDown,
        .leftMouseUp,
        .rightMouseDown,
        .rightMouseUp,
        .mouseMoved,
        .leftMouseDragged,
        .rightMouseDragged,
        .otherMouseDown,
        .otherMouseUp,
        .otherMouseDragged,
        .scrollWheel,
    ]

    private let request: MouseEventObservationRequest
    private let startNanoseconds = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    private let lock = NSLock()
    private var samples: [MouseEventObservationSample] = []

    init(request: MouseEventObservationRequest) {
        self.request = request
    }

    func observe() throws -> [MouseEventObservationSample] {
        let mask = Self.observedTypes.reduce(CGEventMask(0)) { partial, type in
            partial | (CGEventMask(1) << CGEventMask(type.rawValue))
        }
        let activeTaps = try request.tapLocation.observedLocations.map { location in
            try makeTap(location: location, mask: mask)
        }

        let runLoop = CFRunLoopGetCurrent()
        for activeTap in activeTaps {
            CFRunLoopAddSource(runLoop, activeTap.source, .commonModes)
            CGEvent.tapEnable(tap: activeTap.tap, enable: true)
        }
        defer {
            for activeTap in activeTaps {
                CGEvent.tapEnable(tap: activeTap.tap, enable: false)
                CFRunLoopRemoveSource(runLoop, activeTap.source, .commonModes)
                activeTap.context.release()
            }
        }

        runLoopUntilDeadline()

        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    private func makeTap(location: MouseEventTapLocation, mask: CGEventMask) throws -> ActiveMouseEventTap {
        let context = Unmanaged.passRetained(MouseEventTapContext(recorder: self, tapLocation: location))
        guard let tap = CGEvent.tapCreate(
            tap: location.cgEventTapLocation,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: context.toOpaque()
        ) else {
            context.release()
            throw MouseEventObservationError(
                "failed to create \(location.rawValue) mouse event tap; grant Accessibility/Input Monitoring to the terminal running AOSComputerUseCLI"
            )
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            context.release()
            throw MouseEventObservationError("failed to create run loop source for \(location.rawValue) mouse event tap")
        }

        return ActiveMouseEventTap(tap: tap, source: source, context: context)
    }

    private func runLoopUntilDeadline() {
        let duration = TimeInterval(request.durationMilliseconds) / 1_000
        let deadline = Date().addingTimeInterval(duration)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                return
            }
            CFRunLoopRunInMode(.defaultMode, min(remaining, 0.05), false)
        }
    }

    private func record(tapLocation: MouseEventTapLocation, type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            return
        }

        let sample = makeSample(tapLocation: tapLocation, type: type, event: event)
        lock.lock()
        samples.append(sample)
        lock.unlock()
    }

    private func makeSample(tapLocation: MouseEventTapLocation, type: CGEventType, event: CGEvent) -> MouseEventObservationSample {
        let sourcePID = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))
        let targetPID = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        let windowUnderMousePointer = event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
        let windowUnderMousePointerThatCanHandleThisEvent = event.getIntegerValueField(
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent
        )
        let rawField0 = Self.rawField(event, 0)
        let rawField40 = Self.rawField(event, 40)
        let rawField51 = Self.rawField(event, 51)
        let rawField58 = Self.rawField(event, 58)
        let rawField91 = Self.rawField(event, 91)
        let rawField92 = Self.rawField(event, 92)
        let elapsed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - startNanoseconds
        let matchesPID = request.pid.map {
            sourcePID == $0 || targetPID == $0 || rawField40 == Int64($0)
        } ?? true
        let matchesWindow = request.windowId.map {
            let rawWindowID = Int64($0)
            return windowUnderMousePointer == rawWindowID
                || windowUnderMousePointerThatCanHandleThisEvent == rawWindowID
                || rawField51 == rawWindowID
                || rawField91 == rawWindowID
                || rawField92 == rawWindowID
        } ?? true

        return MouseEventObservationSample(
            tapLocation: tapLocation,
            elapsedNanoseconds: elapsed,
            typeRawValue: UInt32(type.rawValue),
            typeName: Self.name(for: type),
            location: event.location,
            sourcePID: sourcePID,
            targetPID: targetPID,
            buttonNumber: event.getIntegerValueField(.mouseEventButtonNumber),
            clickState: event.getIntegerValueField(.mouseEventClickState),
            subtype: event.getIntegerValueField(.mouseEventSubtype),
            windowUnderMousePointer: windowUnderMousePointer,
            windowUnderMousePointerThatCanHandleThisEvent: windowUnderMousePointerThatCanHandleThisEvent,
            rawField0: rawField0,
            rawField40: rawField40,
            rawField51: rawField51,
            rawField58: rawField58,
            rawField91: rawField91,
            rawField92: rawField92,
            matchesRequestedTarget: matchesPID && matchesWindow
        )
    }

    private static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else {
            return Unmanaged.passUnretained(event)
        }
        let context = Unmanaged<MouseEventTapContext>.fromOpaque(refcon).takeUnretainedValue()
        context.recorder.record(tapLocation: context.tapLocation, type: type, event: event)
        return Unmanaged.passUnretained(event)
    }

    private static func rawField(_ event: CGEvent, _ field: UInt32) -> Int64 {
        guard let eventField = CGEventField(rawValue: field) else {
            preconditionFailure("invalid CGEventField raw value \(field)")
        }
        return event.getIntegerValueField(eventField)
    }

    private static func name(for type: CGEventType) -> String {
        switch type {
        case .leftMouseDown: return "leftMouseDown"
        case .leftMouseUp: return "leftMouseUp"
        case .rightMouseDown: return "rightMouseDown"
        case .rightMouseUp: return "rightMouseUp"
        case .mouseMoved: return "mouseMoved"
        case .leftMouseDragged: return "leftMouseDragged"
        case .rightMouseDragged: return "rightMouseDragged"
        case .otherMouseDown: return "otherMouseDown"
        case .otherMouseUp: return "otherMouseUp"
        case .otherMouseDragged: return "otherMouseDragged"
        case .scrollWheel: return "scrollWheel"
        default: return "event-\(type.rawValue)"
        }
    }
}

private struct ActiveMouseEventTap {
    let tap: CFMachPort
    let source: CFRunLoopSource
    let context: Unmanaged<MouseEventTapContext>
}

private final class MouseEventTapContext {
    let recorder: MouseEventTapRecorder
    let tapLocation: MouseEventTapLocation

    init(recorder: MouseEventTapRecorder, tapLocation: MouseEventTapLocation) {
        self.recorder = recorder
        self.tapLocation = tapLocation
    }
}

private struct MouseEventObservationError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }

    init(_ message: String) {
        self.message = message
    }
}

public struct ComputerUseCoreAdapter: ComputerUseCoreClient {
    private let core: ComputerUseCore

    public init(core: ComputerUseCore = ComputerUseCore()) {
        self.core = core
    }

    public func listApps(mode: AppListMode) async throws -> [AppInfo] {
        await core.listApps(mode: mode)
    }

    public func getAppType(pid: pid_t) async throws -> AppTypeResult {
        try await core.getAppType(pid: pid)
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

    public func postMouseEvent(
        pid: pid_t,
        windowId: CGWindowID,
        event: BackgroundMouseEvent
    ) async throws -> WindowMouseEventResult {
        try await core.postMouseEvent(pid: pid, windowId: windowId, event: event)
    }

    public func postMouseEventTrace(
        pid: pid_t,
        windowId: CGWindowID,
        event: BackgroundMouseEvent
    ) async throws -> WindowMouseEventTraceResult {
        try await core.postMouseEventTrace(
            pid: pid,
            windowId: windowId,
            event: event
        )
    }

    public func postKeyboardEvent(
        pid: pid_t,
        windowId: CGWindowID,
        event: BackgroundKeyboardEvent
    ) async throws -> WindowKeyboardEventResult {
        try await core.postKeyboardEvent(pid: pid, windowId: windowId, event: event)
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
          AOSComputerUseCLI get-app-type --pid <pid>
          AOSComputerUseCLI list-windows --pid <pid>
          AOSComputerUseCLI get-app-state --pid <pid> --window-id <id> [--mode vision|ax] [--max-image-dimension <pixels>] [--screenshot-output <path>]
          AOSComputerUseCLI focus-window --pid <pid> --window-id <id>
          AOSComputerUseCLI left-click --pid <pid> --window-id <id> --coor <x,y> [--trace]
          AOSComputerUseCLI right-click --pid <pid> --window-id <id> --coor <x,y> [--trace]
          AOSComputerUseCLI drag --pid <pid> --window-id <id> --from <x,y> --to <x,y> [--button left|right] [--trace]
          AOSComputerUseCLI type-text --pid <pid> --window-id <id> --text <text> [--delay-ms <ms>]
          AOSComputerUseCLI press-key --pid <pid> --window-id <id> --key <key> [--modifiers <modifiers>] [--count <count>]
          AOSComputerUseCLI hotkey --pid <pid> --window-id <id> --keys <modifiers,key>
          AOSComputerUseCLI measure-left-click-window-order --pid <pid> --window-id <id> --coor <x,y> [--runs <count>] [--duration-ms <ms>] [--interval-ms <ms>] [--pre-click-delay-ms <ms>] [--between-runs-ms <ms>]
          AOSComputerUseCLI observe-window-order --pid <pid> --window-id <id> [--duration-ms <ms>] [--interval-ms <ms>]
          AOSComputerUseCLI observe-mouse-events [--pid <pid>] [--window-id <id>] [--duration-ms <ms>] [--tap-location hid|session|annotated|all]
          AOSComputerUseCLI post-cursor [--pid <pid>] [--window-id <id>] [--coor <x,y>]

        Options:
          --json          Emit machine-readable JSON instead of the default readable text.

        Commands:
          grant-permissions  Trigger macOS prompts and open System Settings for required permissions.
          open-coor-test  Open the coordinate click test target as a separate process.
          list-apps       List running apps by default, or all launchable apps with --mode all.
          get-app-type    Show AOS's current app-operation classification for a running pid.
          list-windows    List layer-0 windows owned by a process id.
          get-app-state   Capture AX tree and/or screenshot for a specific app window.
          focus-window    Focus a specific app window without raising it.
          left-click      Post a background left click to a local --coor point.
          right-click     Post a background right click to a local --coor point.
          drag            Post a web-content only background drag from local --from to local --to.
                          Use --trace on mouse-event commands to write per-stage diagnostics to stderr.
          type-text       Type Unicode text into the target pid/window's focused field.
          press-key       Press a single key with optional modifiers against the target pid/window.
          hotkey          Press a keyboard shortcut, e.g. --keys cmd,shift,s.
          measure-left-click-window-order
                          Repeat a background click while measuring active/rank/protected-covered durations.
          observe-window-order
                          Passively sample frontmost app, target rank, and protected-covered count.
          observe-mouse-events
                          Passively capture mouse CGEvent fields for comparing event delivery paths.
          post-cursor
                          Open an interactive mouse-event cursor. Choose an event, use arrow keys to move,
                          Enter executes, Q exits.

        Output:
          Successful commands write readable text to stdout by default.
          Errors write a message to stderr and return non-zero.
        """
    }

    public static func run(
        arguments: [String],
        core: ComputerUseCoreClient,
        permissions: ComputerUsePermissionClient = LiveComputerUsePermissionClient(),
        coorTestTarget: CoorTestTargetClient = LiveCoorTestTargetClient(),
        postCursorIO: PostCursorIO = LivePostCursorIO(),
        postCursorOverlay: PostCursorOverlay = LivePostCursorOverlay(),
        windowOrderObserver: WindowOrderObservationClient = LiveWindowOrderObservationClient(),
        mouseEventObserver: MouseEventObservationClient = LiveMouseEventObservationClient()
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
            case .getAppType(let pid):
                let result = try await core.getAppType(pid: pid)
                return try success(AppTypeOutput(result: result), format: parsed.outputFormat)
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
            case .mouseEventCommand(let request):
                try await requireSupportedMouseEventTarget(request: request, core: core)
                if request.trace {
                    let trace = try await runMouseEventTraceCommand(request: request, core: core)
                    let output = try success(
                        MouseEventPostOutput(request: request, result: trace.result),
                        format: parsed.outputFormat
                    )
                    return ComputerUseCLIResult(
                        stdout: output.stdout,
                        stderr: MouseEventTraceOutput(trace: trace).readableText + "\n",
                        exitCode: output.exitCode
                    )
                }
                let result = try await runMouseEventCommand(request: request, core: core)
                return try success(MouseEventPostOutput(request: request, result: result), format: parsed.outputFormat)
            case .keyboardEventCommand(let request):
                let result = try await core.postKeyboardEvent(
                    pid: request.pid,
                    windowId: request.windowId,
                    event: request.event
                )
                return try success(KeyboardEventPostOutput(request: request, result: result), format: parsed.outputFormat)
            case .measureLeftClickWindowOrder(let request):
                let runs = try await measureLeftClickWindowOrder(
                    request: request,
                    core: core,
                    windowOrderObserver: windowOrderObserver
                )
                return try success(
                    LeftClickWindowOrderMeasurementOutput(request: request, runs: runs),
                    format: parsed.outputFormat
                )
            case .observeWindowOrder(let request):
                let samples = try await windowOrderObserver.observe(request)
                return try success(
                    WindowOrderObservationOutput(request: request, samples: samples),
                    format: parsed.outputFormat
                )
            case .observeMouseEvents(let request):
                let samples = try await mouseEventObserver.observe(request)
                return try success(
                    MouseEventObservationOutput(request: request, samples: samples),
                    format: parsed.outputFormat
                )
            case .postCursor(let request):
                let result = try await runPostCursor(
                    request: request,
                    core: core,
                    io: postCursorIO,
                    overlay: postCursorOverlay
                )
                return try success(PostCursorOutput(result: result), format: parsed.outputFormat)
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

    private static func runMouseEventCommand(
        request: MouseEventCommandRequest,
        core: ComputerUseCoreClient
    ) async throws -> WindowMouseEventResult {
        let event = try await backgroundMouseEvent(request: request, core: core)
        return try await core.postMouseEvent(
            pid: request.pid,
            windowId: request.windowId,
            event: event
        )
    }

    private static func requireSupportedMouseEventTarget(
        request: MouseEventCommandRequest,
        core: ComputerUseCoreClient
    ) async throws {
        guard case .drag = request.event else {
            return
        }
        try await requireWebContentDragTarget(pid: request.pid, core: core)
    }

    private static func requireWebContentDragTarget(
        pid: pid_t,
        core: ComputerUseCoreClient
    ) async throws {
        let appType = try await core.getAppType(pid: pid)
        guard appType.type == .webContent else {
            let appName = appType.appName ?? "pid \(pid)"
            throw UsageError(
                "drag is only supported for web-content targets; \(appName) is \(appType.type.rawValue)"
            )
        }
    }

    private static func measureLeftClickWindowOrder(
        request: LeftClickWindowOrderMeasurementRequest,
        core: ComputerUseCoreClient,
        windowOrderObserver: WindowOrderObservationClient
    ) async throws -> [LeftClickWindowOrderMeasurementRun] {
        let screenPoint = try await screenPoint(
            pid: request.pid,
            windowId: request.windowId,
            coordinate: request.coordinate,
            core: core
        )
        var runs: [LeftClickWindowOrderMeasurementRun] = []
        for runIndex in 1...request.runs {
            let orderRequest = WindowOrderObservationRequest(
                pid: request.pid,
                windowId: request.windowId,
                durationMilliseconds: request.durationMilliseconds,
                intervalMilliseconds: request.intervalMilliseconds
            )
            async let observedSamples = windowOrderObserver.observe(orderRequest)
            await Task.yield()
            try await sleep(milliseconds: request.preClickDelayMilliseconds)
            let click = try await core.postMouseEvent(
                pid: request.pid,
                windowId: request.windowId,
                event: .click(button: .left, point: screenPoint)
            )
            let samples = try await observedSamples
            runs.append(try LeftClickWindowOrderMeasurementRun(
                run: runIndex,
                click: click,
                statistics: WindowOrderObservationStatistics(
                    samples: samples,
                    durationNanoseconds: UInt64(request.durationMilliseconds) * 1_000_000
                ),
                sampleCount: samples.count
            ))
            if runIndex < request.runs {
                try await sleep(milliseconds: request.betweenRunsMilliseconds)
            }
        }
        return runs
    }

    private static func sleep(milliseconds: Int) async throws {
        guard milliseconds > 0 else {
            return
        }
        try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }

    private static func runMouseEventTraceCommand(
        request: MouseEventCommandRequest,
        core: ComputerUseCoreClient
    ) async throws -> WindowMouseEventTraceResult {
        let event = try await backgroundMouseEvent(request: request, core: core)
        return try await core.postMouseEventTrace(
            pid: request.pid,
            windowId: request.windowId,
            event: event
        )
    }

    private static func backgroundMouseEvent(
        request: MouseEventCommandRequest,
        core: ComputerUseCoreClient
    ) async throws -> BackgroundMouseEvent {
        switch request.event {
        case .click(let button, let coordinate):
            return try await .click(
                button: button,
                point: screenPoint(pid: request.pid, windowId: request.windowId, coordinate: coordinate, core: core)
            )
        case .drag(let button, let start, let end):
            return try await .drag(
                button: button,
                from: screenPoint(pid: request.pid, windowId: request.windowId, coordinate: start, core: core),
                to: screenPoint(pid: request.pid, windowId: request.windowId, coordinate: end, core: core)
            )
        }
    }

    private static func screenPoint(
        pid: pid_t,
        windowId: CGWindowID,
        coordinate: CGPoint,
        core: ComputerUseCoreClient
    ) async throws -> CGPoint {
        let windows = try await core.listWindows(pid: pid)
        guard let window = windows.first(where: { $0.id == windowId }) else {
            throw UsageError("window \(windowId) for pid \(pid) is not available")
        }
        return CGPoint(
            x: window.bounds.x + coordinate.x,
            y: window.bounds.y + coordinate.y
        )
    }

    fileprivate static func leftClickPoint(from result: WindowMouseEventResult) throws -> CGPoint {
        guard case .click(.left, let point) = result.event else {
            throw ComputerUseCLIInvariantError("left-click diagnostic received \(result.event)")
        }
        return point
    }

    private static func runPostCursor(
        request: PostCursorRequest,
        core: ComputerUseCoreClient,
        io: PostCursorIO,
        overlay: PostCursorOverlay
    ) async throws -> PostCursorResult {
        let movementStep: CGFloat = 10
        let pid = try await resolvePostCursorPID(request.pid, core: core, io: io)
        let window = try await resolvePostCursorWindow(
            pid: pid,
            requestedWindowId: request.windowId,
            core: core,
            io: io
        )
        let eventKind = try await resolvePostCursorEventKind(io: io)
        if eventKind == .drag {
            try await requireWebContentDragTarget(pid: pid, core: core)
        }
        var localPoint = request.coordinate ?? CGPoint(
            x: floor(window.bounds.width / 2),
            y: floor(window.bounds.height / 2)
        )
        localPoint = clamp(localPoint, to: window.bounds)
        var currentScreenPoint = screenPoint(localPoint: localPoint, window: window)
        var postedEventCount = 0
        var lastEvent: BackgroundMouseEvent?

        try await overlay.show(at: currentScreenPoint)
        await io.write(postCursorStatus(window: window, eventKind: eventKind, localPoint: localPoint))

        do {
            while true {
                switch eventKind {
                case .leftClick, .rightClick:
                    switch try await readPostCursorPoint(
                        localPoint: &localPoint,
                        currentScreenPoint: &currentScreenPoint,
                        window: window,
                        movementStep: movementStep,
                        io: io,
                        overlay: overlay
                    ) {
                    case .confirm:
                        let event = try postCursorPointEvent(
                            eventKind: eventKind,
                            screenPoint: currentScreenPoint
                        )
                        let result = try await core.postMouseEvent(
                            pid: pid,
                            windowId: window.id,
                            event: event
                        )
                        postedEventCount += 1
                        lastEvent = result.event
                        await io.write(postCursorPostedStatus(
                            event: result.event,
                            localPoint: localPoint,
                            window: window,
                            postedEventCount: postedEventCount
                        ))
                    case .quit:
                        await overlay.hide()
                        return finishPostCursor(
                            pid: pid,
                            window: window,
                            point: currentScreenPoint,
                            localPoint: localPoint,
                            eventKind: eventKind,
                            postedEventCount: postedEventCount,
                            lastEvent: lastEvent
                        )
                    }
                case .drag:
                    await io.write("drag start: move cursor, Enter selects start, Q exits\n")
                    switch try await readPostCursorPoint(
                        localPoint: &localPoint,
                        currentScreenPoint: &currentScreenPoint,
                        window: window,
                        movementStep: movementStep,
                        io: io,
                        overlay: overlay
                    ) {
                    case .confirm:
                        break
                    case .quit:
                        await overlay.hide()
                        return finishPostCursor(
                            pid: pid,
                            window: window,
                            point: currentScreenPoint,
                            localPoint: localPoint,
                            eventKind: eventKind,
                            postedEventCount: postedEventCount,
                            lastEvent: lastEvent
                        )
                    }
                    let startLocalPoint = localPoint
                    let startScreenPoint = currentScreenPoint
                    await io.write("drag end: move cursor, Enter posts drag, Q exits\n")
                    switch try await readPostCursorPoint(
                        localPoint: &localPoint,
                        currentScreenPoint: &currentScreenPoint,
                        window: window,
                        movementStep: movementStep,
                        io: io,
                        overlay: overlay
                    ) {
                    case .confirm:
                        let event = BackgroundMouseEvent.drag(
                            button: .left,
                            from: startScreenPoint,
                            to: currentScreenPoint
                        )
                        let result = try await core.postMouseEvent(
                            pid: pid,
                            windowId: window.id,
                            event: event
                        )
                        postedEventCount += 1
                        lastEvent = result.event
                        await io.write(postCursorPostedStatus(
                            event: result.event,
                            localPoint: localPoint,
                            window: window,
                            postedEventCount: postedEventCount,
                            extra: " from local \(Int(startLocalPoint.x)),\(Int(startLocalPoint.y))"
                        ))
                    case .quit:
                        await overlay.hide()
                        return finishPostCursor(
                            pid: pid,
                            window: window,
                            point: currentScreenPoint,
                            localPoint: localPoint,
                            eventKind: eventKind,
                            postedEventCount: postedEventCount,
                            lastEvent: lastEvent
                        )
                    }
                }
            }
        } catch {
            await overlay.hide()
            throw error
        }
    }

    private static func readPostCursorPoint(
        localPoint: inout CGPoint,
        currentScreenPoint: inout CGPoint,
        window: WindowInfo,
        movementStep: CGFloat,
        io: PostCursorIO,
        overlay: PostCursorOverlay
    ) async throws -> PostCursorPointAction {
        while true {
            switch try await io.readKey() {
            case .up:
                localPoint.y -= movementStep
            case .down:
                localPoint.y += movementStep
            case .left:
                localPoint.x -= movementStep
            case .right:
                localPoint.x += movementStep
            case .confirm:
                return .confirm
            case .quit:
                return .quit
            }

            localPoint = clamp(localPoint, to: window.bounds)
            currentScreenPoint = screenPoint(localPoint: localPoint, window: window)
            try await overlay.move(to: currentScreenPoint)
            await io.write(postCursorPositionStatus(localPoint: localPoint, screenPoint: currentScreenPoint))
        }
    }

    private static func postCursorPointEvent(
        eventKind: PostCursorEventKind,
        screenPoint: CGPoint
    ) throws -> BackgroundMouseEvent {
        switch eventKind {
        case .leftClick:
            return .click(button: .left, point: screenPoint)
        case .rightClick:
            return .click(button: .right, point: screenPoint)
        case .drag:
            throw ComputerUseCLIInvariantError("drag does not use point event conversion")
        }
    }

    private static func resolvePostCursorEventKind(io: PostCursorIO) async throws -> PostCursorEventKind {
        let raw = try await io.readLine(prompt: "Select mouse event (left-click/right-click/drag): ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let eventKind = PostCursorEventKind(rawValue: raw) else {
            throw UsageError("invalid mouse event selection: \(raw)")
        }
        return eventKind
    }

    private static func finishPostCursor(
        pid: pid_t,
        window: WindowInfo,
        point: CGPoint,
        localPoint: CGPoint,
        eventKind: PostCursorEventKind,
        postedEventCount: Int,
        lastEvent: BackgroundMouseEvent?
    ) -> PostCursorResult {
        PostCursorResult(
            pid: pid,
            windowId: window.id,
            point: point,
            localPoint: localPoint,
            eventKind: eventKind,
            postedEventCount: postedEventCount,
            lastEvent: lastEvent
        )
    }

    private static func resolvePostCursorPID(
        _ requestedPID: pid_t?,
        core: ComputerUseCoreClient,
        io: PostCursorIO
    ) async throws -> pid_t {
        if let requestedPID {
            return requestedPID
        }

        let apps = try await core.listApps(mode: .running).filter { $0.pid != nil }
        if apps.isEmpty {
            throw UsageError("no running apps with process ids are available")
        }
        await io.write("Apps\n")
        for app in apps {
            await io.write("\(app.name) pid \(app.pid!)\n")
        }
        let raw = try await io.readLine(prompt: "Select pid: ")
        guard let selected = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw UsageError("invalid app selection: \(raw)")
        }
        guard selected > 0 else {
            throw UsageError("invalid app selection: \(raw)")
        }
        return pid_t(selected)
    }

    private static func resolvePostCursorWindow(
        pid: pid_t,
        requestedWindowId: CGWindowID?,
        core: ComputerUseCoreClient,
        io: PostCursorIO
    ) async throws -> WindowInfo {
        let windows = try await core.listWindows(pid: pid)
        if let requestedWindowId {
            guard let window = windows.first(where: { $0.id == requestedWindowId }) else {
                throw UsageError("window \(requestedWindowId) for pid \(pid) is not available")
            }
            return window
        }

        if windows.isEmpty {
            throw UsageError("pid \(pid) has no layer-0 windows")
        }
        await io.write("Windows for pid \(pid)\n")
        for window in windows {
            let title = window.title.isEmpty ? "(untitled)" : window.title
            await io.write("\(window.id) \(title) \(Int(window.bounds.width))x\(Int(window.bounds.height)) @ \(Int(window.bounds.x)),\(Int(window.bounds.y))\n")
        }
        let raw = try await io.readLine(prompt: "Select window id: ")
        guard let selected = UInt32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw UsageError("invalid window selection: \(raw)")
        }
        guard let window = windows.first(where: { $0.id == selected }) else {
            throw UsageError("window \(selected) for pid \(pid) is not available")
        }
        return window
    }

    private static func screenPoint(localPoint: CGPoint, window: WindowInfo) -> CGPoint {
        CGPoint(x: window.bounds.x + localPoint.x, y: window.bounds.y + localPoint.y)
    }

    private static func clamp(_ point: CGPoint, to bounds: WindowBounds) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), max(bounds.width - 1, 0)),
            y: min(max(point.y, 0), max(bounds.height - 1, 0))
        )
    }

    private static func postCursorStatus(
        window: WindowInfo,
        eventKind: PostCursorEventKind,
        localPoint: CGPoint
    ) -> String {
        """
        Post cursor attached to window \(window.id) (pid \(window.pid)).
        Event: \(eventKind.rawValue).
        Arrow keys move the cursor. Enter executes. Q exits.
        \(postCursorPositionStatus(localPoint: localPoint, screenPoint: screenPoint(localPoint: localPoint, window: window)))

        """
    }

    private static func postCursorPositionStatus(localPoint: CGPoint, screenPoint: CGPoint) -> String {
        "cursor local \(Int(localPoint.x)),\(Int(localPoint.y)) screen \(Int(screenPoint.x)),\(Int(screenPoint.y))\n"
    }

    private static func postCursorPostedStatus(
        event: BackgroundMouseEvent,
        localPoint: CGPoint,
        window: WindowInfo,
        postedEventCount: Int,
        extra: String = ""
    ) -> String {
        "posted \(postCursorEventName(event)) #\(postedEventCount) at local \(Int(localPoint.x)),\(Int(localPoint.y))\(extra). Enter executes again. Q exits.\n"
    }

    private static func postCursorEventName(_ event: BackgroundMouseEvent) -> String {
        switch event {
        case .click(let button, _):
            "\(button.rawValue)-click"
        case .drag(let button, _, _):
            "\(button.rawValue)-drag"
        }
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
        case getAppType(pid: pid_t)
        case listWindows(pid: pid_t)
        case getAppState(AppStateRequest)
        case focusWindow(FocusWindowRequest)
        case mouseEventCommand(MouseEventCommandRequest)
        case keyboardEventCommand(KeyboardEventCommandRequest)
        case measureLeftClickWindowOrder(LeftClickWindowOrderMeasurementRequest)
        case observeWindowOrder(WindowOrderObservationRequest)
        case observeMouseEvents(MouseEventObservationRequest)
        case postCursor(PostCursorRequest)
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
        case "get-app-type":
            let pid = try options.requiredPID("--pid")
            try options.rejectUnused()
            command = .getAppType(pid: pid)
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
        case "left-click":
            let pid = try options.requiredPID("--pid")
            let windowId = try options.requiredWindowID("--window-id")
            let coordinate = try options.requiredPoint("--coor")
            let trace = try options.takeFlag("--trace")
            try options.rejectUnused()
            command = .mouseEventCommand(MouseEventCommandRequest(
                pid: pid,
                windowId: windowId,
                event: .click(button: .left, coordinate: coordinate),
                trace: trace
            ))
        case "right-click":
            let pid = try options.requiredPID("--pid")
            let windowId = try options.requiredWindowID("--window-id")
            let coordinate = try options.requiredPoint("--coor")
            let trace = try options.takeFlag("--trace")
            try options.rejectUnused()
            command = .mouseEventCommand(MouseEventCommandRequest(
                pid: pid,
                windowId: windowId,
                event: .click(button: .right, coordinate: coordinate),
                trace: trace
            ))
        case "drag":
            let pid = try options.requiredPID("--pid")
            let windowId = try options.requiredWindowID("--window-id")
            let start = try options.requiredPoint("--from")
            let end = try options.requiredPoint("--to")
            let button = try options.optionalEnum("--button", BackgroundMouseButton.self) ?? .left
            let trace = try options.takeFlag("--trace")
            try options.rejectUnused()
            command = .mouseEventCommand(MouseEventCommandRequest(
                pid: pid,
                windowId: windowId,
                event: .drag(button: button, start: start, end: end),
                trace: trace
            ))
        case "type-text":
            let pid = try options.requiredPID("--pid")
            let windowId = try options.requiredWindowID("--window-id")
            let text = try options.requiredPublicString("--text")
            let delayMilliseconds = try options.optionalInt("--delay-ms") ?? 30
            try options.rejectUnused()
            command = .keyboardEventCommand(KeyboardEventCommandRequest(
                pid: pid,
                windowId: windowId,
                event: .text(text, delayMilliseconds: delayMilliseconds)
            ))
        case "press-key":
            let pid = try options.requiredPID("--pid")
            let windowId = try options.requiredWindowID("--window-id")
            let key = try options.requiredPublicString("--key")
            let modifiers = try options.optionalModifierList("--modifiers")
            let count = try options.optionalPositiveInt("--count") ?? 1
            try options.rejectUnused()
            command = .keyboardEventCommand(KeyboardEventCommandRequest(
                pid: pid,
                windowId: windowId,
                event: .keyPress(key: key, modifiers: modifiers, count: count)
            ))
        case "hotkey":
            let pid = try options.requiredPID("--pid")
            let windowId = try options.requiredWindowID("--window-id")
            let keys = try options.requiredKeyList("--keys")
            guard let key = keys.last else {
                throw UsageError("missing required option --keys")
            }
            let modifiers = try keys.dropLast().map { try BackgroundKeyboardModifier.cliValue($0) }
            try options.rejectUnused()
            command = .keyboardEventCommand(KeyboardEventCommandRequest(
                pid: pid,
                windowId: windowId,
                event: .hotkey(modifiers: modifiers, key: key)
            ))
        case "measure-left-click-window-order":
            let pid = try options.requiredPID("--pid")
            let windowId = try options.requiredWindowID("--window-id")
            let coordinate = try options.requiredPoint("--coor")
            let runs = try options.optionalPositiveInt("--runs") ?? 10
            let durationMilliseconds = try options.optionalPositiveInt("--duration-ms") ?? 8_000
            let intervalMilliseconds = try options.optionalPositiveInt("--interval-ms") ?? 1
            let preClickDelayMilliseconds = try options.optionalInt("--pre-click-delay-ms") ?? 2_000
            let betweenRunsMilliseconds = try options.optionalInt("--between-runs-ms") ?? 300
            try options.rejectUnused()
            command = .measureLeftClickWindowOrder(LeftClickWindowOrderMeasurementRequest(
                pid: pid,
                windowId: windowId,
                coordinate: coordinate,
                runs: runs,
                durationMilliseconds: durationMilliseconds,
                intervalMilliseconds: intervalMilliseconds,
                preClickDelayMilliseconds: preClickDelayMilliseconds,
                betweenRunsMilliseconds: betweenRunsMilliseconds
            ))
        case "observe-window-order":
            let pid = try options.requiredPID("--pid")
            let windowId = try options.requiredWindowID("--window-id")
            let durationMilliseconds = try options.optionalPositiveInt("--duration-ms") ?? 5_000
            let intervalMilliseconds = try options.optionalPositiveInt("--interval-ms") ?? 5
            try options.rejectUnused()
            command = .observeWindowOrder(WindowOrderObservationRequest(
                pid: pid,
                windowId: windowId,
                durationMilliseconds: durationMilliseconds,
                intervalMilliseconds: intervalMilliseconds
            ))
        case "observe-mouse-events":
            let pid = try options.optionalPID("--pid")
            let windowId = try options.optionalWindowID("--window-id")
            let durationMilliseconds = try options.optionalPositiveInt("--duration-ms") ?? 5_000
            let tapLocation = try options.optionalEnum("--tap-location", MouseEventTapLocation.self) ?? .all
            try options.rejectUnused()
            command = .observeMouseEvents(MouseEventObservationRequest(
                pid: pid,
                windowId: windowId,
                durationMilliseconds: durationMilliseconds,
                tapLocation: tapLocation
            ))
        case "post-cursor":
            let pid = try options.optionalPID("--pid")
            let windowId = try options.optionalWindowID("--window-id")
            let coordinate = try options.optionalPoint("--coor")
            try options.rejectUnused()
            command = .postCursor(PostCursorRequest(pid: pid, windowId: windowId, coordinate: coordinate))
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

    mutating func optionalPID(_ name: String) throws -> pid_t? {
        guard let value = try takeValue(name) else { return nil }
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

    mutating func optionalWindowID(_ name: String) throws -> CGWindowID? {
        guard let value = try takeValue(name) else { return nil }
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

    mutating func optionalPositiveInt(_ name: String) throws -> Int? {
        guard let value = try takeValue(name) else { return nil }
        guard let parsed = Int(value), parsed > 0 else {
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

    mutating func requiredPublicString(_ name: String) throws -> String {
        try requiredString(name)
    }

    mutating func optionalModifierList(_ name: String) throws -> [BackgroundKeyboardModifier] {
        guard let raw = try takeValue(name) else {
            return []
        }
        return try splitCommaList(raw).map { try BackgroundKeyboardModifier.cliValue($0) }
    }

    mutating func requiredKeyList(_ name: String) throws -> [String] {
        let raw = try requiredString(name)
        let keys = splitCommaList(raw)
        guard keys.count >= 2 else {
            throw UsageError("invalid value for \(name): \(raw); expected modifiers,key")
        }
        return keys
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

    private func splitCommaList(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private extension BackgroundKeyboardModifier {
    static func cliValue(_ raw: String) throws -> BackgroundKeyboardModifier {
        switch raw.lowercased() {
        case "cmd", "command":
            return .command
        case "shift":
            return .shift
        case "option", "alt":
            return .option
        case "ctrl", "control":
            return .control
        case "fn", "function":
            return .function
        default:
            throw UsageError("invalid keyboard modifier: \(raw)")
        }
    }
}

private struct UsageError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }

    init(_ message: String) {
        self.message = message
    }
}

private struct ComputerUseCLIInvariantError: Error, CustomStringConvertible {
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

private struct MouseEventCommandRequest: Sendable {
    let pid: pid_t
    let windowId: CGWindowID
    let event: MouseEventCommand
    let trace: Bool
}

private struct KeyboardEventCommandRequest: Sendable {
    let pid: pid_t
    let windowId: CGWindowID
    let event: BackgroundKeyboardEvent
}

private enum MouseEventCommand: Sendable, Equatable {
    case click(button: BackgroundMouseButton, coordinate: CGPoint)
    case drag(button: BackgroundMouseButton, start: CGPoint, end: CGPoint)

    var commandName: String {
        switch self {
        case .click(.left, _):
            return "left-click"
        case .click(.right, _):
            return "right-click"
        case .drag:
            return "drag"
        }
    }
}

private struct LeftClickWindowOrderMeasurementRequest: Sendable {
    let pid: pid_t
    let windowId: CGWindowID
    let coordinate: CGPoint
    let runs: Int
    let durationMilliseconds: Int
    let intervalMilliseconds: Int
    let preClickDelayMilliseconds: Int
    let betweenRunsMilliseconds: Int
}

private struct PostCursorRequest: Sendable {
    let pid: pid_t?
    let windowId: CGWindowID?
    let coordinate: CGPoint?
}

private enum PostCursorEventKind: String, Sendable, Equatable {
    case leftClick = "left-click"
    case rightClick = "right-click"
    case drag
}

private enum PostCursorPointAction: Sendable, Equatable {
    case confirm
    case quit
}

private struct PostCursorResult: Sendable, Equatable {
    let pid: pid_t
    let windowId: CGWindowID
    let point: CGPoint
    let localPoint: CGPoint
    let eventKind: PostCursorEventKind
    let postedEventCount: Int
    let lastEvent: BackgroundMouseEvent?
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

private struct AppTypeOutput: Encodable, ReadableOutput {
    let command = "get-app-type"
    let pid: pid_t
    let appName: String?
    let bundleId: String?
    let bundlePath: String?
    let type: String
    let reason: String

    init(result: AppTypeResult) {
        self.pid = result.pid
        self.appName = result.appName
        self.bundleId = result.bundleId
        self.bundlePath = result.bundlePath
        self.type = result.type.rawValue
        self.reason = result.reason.rawValue
    }

    var readableText: String {
        var lines = ["App type for pid \(pid)"]
        lines.append("- name: \(appName ?? "nil")")
        lines.append("- bundleId: \(bundleId ?? "nil")")
        lines.append("- type: \(type)")
        lines.append("- reason: \(reason)")
        lines.append("- bundlePath: \(bundlePath ?? "nil")")
        return lines.joined(separator: "\n")
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

private struct MouseEventPostOutput: Encodable, ReadableOutput {
    let command: String
    let pid: pid_t
    let windowId: CGWindowID
    let event: String
    let point: PointOutput?
    let from: PointOutput?
    let to: PointOutput?

    init(request: MouseEventCommandRequest, result: WindowMouseEventResult) {
        self.command = request.event.commandName
        self.pid = result.pid
        self.windowId = result.windowId
        self.event = Self.eventName(result.event)
        switch result.event {
        case .click(_, let point):
            self.point = PointOutput(point)
            self.from = nil
            self.to = nil
        case .drag(_, let start, let end):
            self.point = nil
            self.from = PointOutput(start)
            self.to = PointOutput(end)
        }
    }

    var readableText: String {
        switch (point, from, to) {
        case (let point?, nil, nil):
            return "Posted \(event) to window \(windowId) at \(Int(point.x)),\(Int(point.y)) (pid \(pid))."
        case (nil, let from?, let to?):
            return "Posted \(event) to window \(windowId) from \(Int(from.x)),\(Int(from.y)) to \(Int(to.x)),\(Int(to.y)) (pid \(pid))."
        default:
            return "Posted \(event) to window \(windowId) (pid \(pid))."
        }
    }

    private static func eventName(_ event: BackgroundMouseEvent) -> String {
        switch event {
        case .click(let button, _):
            return "\(button.rawValue) click"
        case .drag(let button, _, _):
            return "\(button.rawValue) drag"
        }
    }
}

private struct KeyboardEventPostOutput: Encodable, ReadableOutput {
    let command: String
    let pid: pid_t
    let windowId: CGWindowID
    let event: String

    init(request: KeyboardEventCommandRequest, result: WindowKeyboardEventResult) {
        self.command = Self.commandName(request.event)
        self.pid = result.pid
        self.windowId = result.windowId
        self.event = result.event.description
    }

    var readableText: String {
        "Posted keyboard event \(event) to window \(windowId) (pid \(pid))."
    }

    private static func commandName(_ event: BackgroundKeyboardEvent) -> String {
        switch event {
        case .text:
            return "type-text"
        case .keyPress:
            return "press-key"
        case .hotkey:
            return "hotkey"
        }
    }
}

private struct MouseEventTraceOutput: ReadableOutput {
    let trace: WindowMouseEventTraceResult

    var readableText: String {
        var lines = ["Mouse event trace:"]
        lines.append(contentsOf: trace.snapshots.map(Self.line))
        return lines.joined(separator: "\n")
    }

    private static func line(_ snapshot: WindowMouseEventTraceSnapshot) -> String {
        let frontmost = snapshot.frontmostPID.map { "pid \($0)" } ?? "pid nil"
        let bundle = snapshot.frontmostBundleIdentifier.map { " bundle \($0)" } ?? ""
        let window = snapshot.frontmostWindowId.map { " window \($0)" } ?? " window nil"
        let rank = snapshot.targetRank.map(String.init) ?? "nil"
        let covered = snapshot.protectedCoveredCount.map(String.init) ?? "nil"
        let elapsed = snapshot.elapsedNanoseconds.map { ", elapsed-ms \($0 / 1_000_000)" } ?? ""
        let attempt = snapshot.guardAttempt.map { ", attempt \($0)" } ?? ""
        let corrected = snapshot.corrected.map { ", corrected \($0)" } ?? ""
        return "\(snapshot.stage.rawValue): frontmost \(frontmost)\(bundle)\(window), target active \(snapshot.targetIsActive), target rank \(rank), protected-covered \(covered)\(elapsed)\(attempt)\(corrected)"
    }
}

private struct LeftClickWindowOrderMeasurementOutput: Encodable, ReadableOutput {
    let command = "measure-left-click-window-order"
    let pid: pid_t
    let windowId: CGWindowID
    let coordinate: PointOutput
    let runsRequested: Int
    let durationMilliseconds: Int
    let intervalMilliseconds: Int
    let preClickDelayMilliseconds: Int
    let betweenRunsMilliseconds: Int
    let protectedCoveredObservedRuns: Int
    let maxActiveContiguousMilliseconds: UInt64
    let maxRankOneContiguousMilliseconds: UInt64
    let maxProtectedCoveredContiguousMilliseconds: UInt64
    let runResults: [LeftClickWindowOrderMeasurementRun]

    init(request: LeftClickWindowOrderMeasurementRequest, runs: [LeftClickWindowOrderMeasurementRun]) {
        self.pid = request.pid
        self.windowId = request.windowId
        self.coordinate = PointOutput(request.coordinate)
        self.runsRequested = request.runs
        self.durationMilliseconds = request.durationMilliseconds
        self.intervalMilliseconds = request.intervalMilliseconds
        self.preClickDelayMilliseconds = request.preClickDelayMilliseconds
        self.betweenRunsMilliseconds = request.betweenRunsMilliseconds
        self.protectedCoveredObservedRuns = runs.filter(\.protectedCoveredObserved).count
        self.maxActiveContiguousMilliseconds = runs.map(\.targetActiveMaxContiguousMilliseconds).max() ?? 0
        self.maxRankOneContiguousMilliseconds = runs.map(\.targetRankOneMaxContiguousMilliseconds).max() ?? 0
        self.maxProtectedCoveredContiguousMilliseconds = runs
            .map(\.protectedCoveredMaxContiguousMilliseconds)
            .max() ?? 0
        self.runResults = runs
    }

    var readableText: String {
        var lines = [
            "Left click window order measurement",
            "Target: pid \(pid), window \(windowId), coor \(Int(coordinate.x)),\(Int(coordinate.y))",
            "Runs: \(runResults.count), protected-covered-observed \(protectedCoveredObservedRuns)/\(runResults.count)",
            "Summary: max active contiguous \(maxActiveContiguousMilliseconds)ms, max rank1 contiguous \(maxRankOneContiguousMilliseconds)ms, max protected-covered contiguous \(maxProtectedCoveredContiguousMilliseconds)ms",
            "",
            "Run details:",
        ]
        lines.append(contentsOf: runResults.map(\.readableText))
        return lines.joined(separator: "\n")
    }
}

private struct LeftClickWindowOrderMeasurementRun: Encodable {
    let run: Int
    let clickedPoint: PointOutput
    let sampleCount: Int
    let targetActiveTotalMilliseconds: UInt64
    let targetActiveMaxContiguousMilliseconds: UInt64
    let targetRankOneTotalMilliseconds: UInt64
    let targetRankOneMaxContiguousMilliseconds: UInt64
    let protectedCoveredTotalMilliseconds: UInt64
    let protectedCoveredMaxContiguousMilliseconds: UInt64
    let protectedCoveredApproximate60HzFrames: UInt64
    let protectedCoveredObserved: Bool

    init(
        run: Int,
        click: WindowMouseEventResult,
        statistics: WindowOrderObservationStatistics,
        sampleCount: Int
    ) throws {
        self.run = run
        self.clickedPoint = PointOutput(try ComputerUseCLI.leftClickPoint(from: click))
        self.sampleCount = sampleCount
        self.targetActiveTotalMilliseconds = statistics.targetActive.totalMilliseconds
        self.targetActiveMaxContiguousMilliseconds = statistics.targetActive.maxContiguousMilliseconds
        self.targetRankOneTotalMilliseconds = statistics.targetRankOne.totalMilliseconds
        self.targetRankOneMaxContiguousMilliseconds = statistics.targetRankOne.maxContiguousMilliseconds
        self.protectedCoveredTotalMilliseconds = statistics.protectedCovered.totalMilliseconds
        self.protectedCoveredMaxContiguousMilliseconds = statistics.protectedCovered.maxContiguousMilliseconds
        self.protectedCoveredApproximate60HzFrames = statistics.protectedCovered.approximate60HzFrames
        self.protectedCoveredObserved = statistics.protectedCovered.totalNanoseconds > 0
    }

    var readableText: String {
        "Run \(run): active \(targetActiveTotalMilliseconds)ms, rank1 \(targetRankOneTotalMilliseconds)ms, protected-covered \(protectedCoveredTotalMilliseconds)ms, frames \(protectedCoveredApproximate60HzFrames), samples \(sampleCount)"
    }
}

private struct WindowOrderObservationOutput: Encodable, ReadableOutput {
    let command = "observe-window-order"
    let pid: pid_t
    let windowId: CGWindowID
    let durationMilliseconds: Int
    let intervalMilliseconds: Int
    let sampleCount: Int
    let transitionCount: Int
    let targetRankChanged: Bool
    let targetBecameActive: Bool
    let maxProtectedCoveredCount: Int?
    let targetActiveTotalMilliseconds: UInt64
    let targetActiveMaxContiguousMilliseconds: UInt64
    let targetRankOneTotalMilliseconds: UInt64
    let targetRankOneMaxContiguousMilliseconds: UInt64
    let protectedCoveredTotalMilliseconds: UInt64
    let protectedCoveredMaxContiguousMilliseconds: UInt64
    let protectedCoveredApproximate60HzFrames: UInt64
    let samples: [WindowOrderObservationSample]

    init(request: WindowOrderObservationRequest, samples: [WindowOrderObservationSample]) {
        let statistics = WindowOrderObservationStatistics(
            samples: samples,
            durationNanoseconds: UInt64(request.durationMilliseconds) * 1_000_000
        )
        self.pid = request.pid
        self.windowId = request.windowId
        self.durationMilliseconds = request.durationMilliseconds
        self.intervalMilliseconds = request.intervalMilliseconds
        self.sampleCount = samples.count
        self.transitionCount = Self.transitions(samples).count
        self.targetRankChanged = Self.rankChanged(samples)
        self.targetBecameActive = samples.contains(where: \.targetIsActive)
        self.maxProtectedCoveredCount = samples.compactMap(\.protectedCoveredCount).max()
        self.samples = samples
        self.targetActiveTotalMilliseconds = statistics.targetActive.totalMilliseconds
        self.targetActiveMaxContiguousMilliseconds = statistics.targetActive.maxContiguousMilliseconds
        self.targetRankOneTotalMilliseconds = statistics.targetRankOne.totalMilliseconds
        self.targetRankOneMaxContiguousMilliseconds = statistics.targetRankOne.maxContiguousMilliseconds
        self.protectedCoveredTotalMilliseconds = statistics.protectedCovered.totalMilliseconds
        self.protectedCoveredMaxContiguousMilliseconds = statistics.protectedCovered.maxContiguousMilliseconds
        self.protectedCoveredApproximate60HzFrames = statistics.protectedCovered.approximate60HzFrames
    }

    var readableText: String {
        var lines = [
            "Window order observation",
            "Target: pid \(pid), window \(windowId)",
            "Duration: \(durationMilliseconds)ms, interval: \(intervalMilliseconds)ms, samples: \(sampleCount)",
            "Summary: rank-changed \(targetRankChanged), target-active-observed \(targetBecameActive), max protected-covered \(maxProtectedCoveredCount.map(String.init) ?? "nil")",
            "Durations: active total \(targetActiveTotalMilliseconds)ms, max-contiguous \(targetActiveMaxContiguousMilliseconds)ms",
            "Durations: rank1 total \(targetRankOneTotalMilliseconds)ms, max-contiguous \(targetRankOneMaxContiguousMilliseconds)ms",
            "Durations: protected-covered total \(protectedCoveredTotalMilliseconds)ms, max-contiguous \(protectedCoveredMaxContiguousMilliseconds)ms",
            "Durations: protected-covered 60hz frames approx \(protectedCoveredApproximate60HzFrames)",
            "",
            "Timeline changes:",
        ]
        lines.append(contentsOf: Self.transitions(samples).map(Self.line))
        return lines.joined(separator: "\n")
    }

    private static func rankChanged(_ samples: [WindowOrderObservationSample]) -> Bool {
        let ranks = samples.compactMap(\.targetRank)
        guard let first = ranks.first else {
            return false
        }
        return ranks.contains { $0 != first }
    }

    private static func transitions(
        _ samples: [WindowOrderObservationSample]
    ) -> [WindowOrderObservationSample] {
        var previous: WindowOrderObservationState?
        return samples.filter { sample in
            let state = WindowOrderObservationState(sample)
            defer { previous = state }
            return state != previous
        }
    }

    private static func line(_ sample: WindowOrderObservationSample) -> String {
        let elapsed = sample.elapsedNanoseconds / 1_000_000
        let frontmost = sample.frontmostPID.map { "pid \($0)" } ?? "pid nil"
        let bundle = sample.frontmostBundleIdentifier.map { " bundle \($0)" } ?? ""
        let window = sample.frontmostWindowId.map { " window \($0)" } ?? " window nil"
        let rank = sample.targetRank.map(String.init) ?? "nil"
        let covered = sample.protectedCoveredCount.map(String.init) ?? "nil"
        let originalFrontActive = sample.originalFrontmostIsActive
            .map { ", original-front active \($0)" } ?? ""
        return "\(elapsed)ms: frontmost \(frontmost)\(bundle)\(window), target active \(sample.targetIsActive), target rank \(rank), protected-covered \(covered)\(originalFrontActive)"
    }
}

private struct WindowOrderObservationStatistics: Encodable {
    let targetActive: WindowOrderObservationDuration
    let targetRankOne: WindowOrderObservationDuration
    let protectedCovered: WindowOrderObservationDuration

    init(samples: [WindowOrderObservationSample], durationNanoseconds: UInt64) {
        self.targetActive = Self.duration(
            samples: samples,
            durationNanoseconds: durationNanoseconds,
            predicate: { $0.targetIsActive }
        )
        self.targetRankOne = Self.duration(
            samples: samples,
            durationNanoseconds: durationNanoseconds,
            predicate: { $0.targetRank == 1 }
        )
        self.protectedCovered = Self.duration(
            samples: samples,
            durationNanoseconds: durationNanoseconds,
            predicate: { ($0.protectedCoveredCount ?? 0) > 0 }
        )
    }

    private static func duration(
        samples: [WindowOrderObservationSample],
        durationNanoseconds: UInt64,
        predicate: (WindowOrderObservationSample) -> Bool
    ) -> WindowOrderObservationDuration {
        guard !samples.isEmpty else {
            return WindowOrderObservationDuration(totalNanoseconds: 0, maxContiguousNanoseconds: 0)
        }

        var total: UInt64 = 0
        var current: UInt64 = 0
        var maxContiguous: UInt64 = 0

        for index in samples.indices {
            let sample = samples[index]
            let nextIndex = samples.index(after: index)
            let nextElapsed: UInt64
            if nextIndex < samples.endIndex {
                let nextSample = samples[nextIndex]
                precondition(
                    nextSample.elapsedNanoseconds >= sample.elapsedNanoseconds,
                    "window order observation samples must be chronological"
                )
                nextElapsed = nextSample.elapsedNanoseconds
            } else {
                nextElapsed = max(sample.elapsedNanoseconds, durationNanoseconds)
            }

            let segmentDuration = nextElapsed - sample.elapsedNanoseconds
            guard predicate(sample) else {
                maxContiguous = max(maxContiguous, current)
                current = 0
                continue
            }

            total += segmentDuration
            current += segmentDuration
        }

        maxContiguous = max(maxContiguous, current)
        return WindowOrderObservationDuration(
            totalNanoseconds: total,
            maxContiguousNanoseconds: maxContiguous
        )
    }
}

private struct WindowOrderObservationDuration: Encodable {
    let totalNanoseconds: UInt64
    let maxContiguousNanoseconds: UInt64

    var totalMilliseconds: UInt64 {
        totalNanoseconds / 1_000_000
    }

    var maxContiguousMilliseconds: UInt64 {
        maxContiguousNanoseconds / 1_000_000
    }

    var approximate60HzFrames: UInt64 {
        guard maxContiguousNanoseconds > 0 else {
            return 0
        }
        return (maxContiguousNanoseconds * 60 + 999_999_999) / 1_000_000_000
    }
}

private struct WindowOrderObservationState: Equatable {
    let frontmostPID: pid_t?
    let frontmostBundleIdentifier: String?
    let frontmostWindowId: CGWindowID?
    let targetIsActive: Bool
    let targetRank: Int?
    let protectedCoveredCount: Int?
    let originalFrontmostIsActive: Bool?

    init(_ sample: WindowOrderObservationSample) {
        self.frontmostPID = sample.frontmostPID
        self.frontmostBundleIdentifier = sample.frontmostBundleIdentifier
        self.frontmostWindowId = sample.frontmostWindowId
        self.targetIsActive = sample.targetIsActive
        self.targetRank = sample.targetRank
        self.protectedCoveredCount = sample.protectedCoveredCount
        self.originalFrontmostIsActive = sample.originalFrontmostIsActive
    }
}

private struct MouseEventObservationOutput: Encodable, ReadableOutput {
    let command = "observe-mouse-events"
    let pid: pid_t?
    let windowId: CGWindowID?
    let durationMilliseconds: Int
    let tapLocation: MouseEventTapLocation
    let eventCount: Int
    let samples: [MouseEventObservationSample]

    init(request: MouseEventObservationRequest, samples: [MouseEventObservationSample]) {
        self.pid = request.pid
        self.windowId = request.windowId
        self.durationMilliseconds = request.durationMilliseconds
        self.tapLocation = request.tapLocation
        self.eventCount = samples.count
        self.samples = samples
    }

    var readableText: String {
        var lines = ["Mouse event observation"]
        if let pid, let windowId {
            lines.append("Target: pid \(pid), window \(windowId)")
        } else if let pid {
            lines.append("Target: pid \(pid)")
        } else if let windowId {
            lines.append("Target: window \(windowId)")
        } else {
            lines.append("Target: all mouse events")
        }
        lines.append("Taps: \(tapLocation.rawValue)")
        lines.append("Duration: \(durationMilliseconds)ms, events: \(eventCount)")
        if samples.isEmpty {
            return lines.joined(separator: "\n")
        }
        lines.append("")
        lines.append("Events:")
        lines.append(contentsOf: samples.map(Self.line))
        return lines.joined(separator: "\n")
    }

    private static func line(_ sample: MouseEventObservationSample) -> String {
        let match = sample.matchesRequestedTarget ? " match" : ""
        return "\(sample.elapsedNanoseconds / 1_000_000)ms: \(sample.tapLocation.rawValue) \(sample.typeName) "
            + "loc \(Int(sample.location.x)),\(Int(sample.location.y))\(match), "
            + "source-pid \(sample.sourcePID) target-pid \(sample.targetPID), "
            + "button \(sample.buttonNumber) click-state \(sample.clickState) "
            + "subtype \(sample.subtype), "
            + "window-under \(sample.windowUnderMousePointer) "
            + "can-handle \(sample.windowUnderMousePointerThatCanHandleThisEvent), "
            + "raw[0]=\(sample.rawField0) raw[40]=\(sample.rawField40) "
            + "raw[51]=\(sample.rawField51) raw[58]=\(sample.rawField58) "
            + "raw[91]=\(sample.rawField91) raw[92]=\(sample.rawField92)"
    }
}

private struct PostCursorOutput: Encodable, ReadableOutput {
    let command = "post-cursor"
    let pid: pid_t
    let windowId: CGWindowID
    let event: String
    let point: PointOutput
    let localPoint: PointOutput
    let postedEventCount: Int
    let lastEvent: String?

    init(result: PostCursorResult) {
        self.pid = result.pid
        self.windowId = result.windowId
        self.event = result.eventKind.rawValue
        self.point = PointOutput(result.point)
        self.localPoint = PointOutput(result.localPoint)
        self.postedEventCount = result.postedEventCount
        self.lastEvent = result.lastEvent?.description
    }

    var readableText: String {
        if postedEventCount > 0 {
            return "Post cursor exited after \(postedEventCount) \(event) event(s) at local \(Int(localPoint.x)),\(Int(localPoint.y)) / screen \(Int(point.x)),\(Int(point.y)) (pid \(pid))."
        }
        return "Post cursor exited without posting \(event) at local \(Int(localPoint.x)),\(Int(localPoint.y)) / screen \(Int(point.x)),\(Int(point.y)) (pid \(pid))."
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
