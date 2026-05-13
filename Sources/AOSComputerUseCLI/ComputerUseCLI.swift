import AOSComputerUseKit
import CoreGraphics
import Darwin
import Foundation

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
          AOSComputerUseCLI start-app-session --pid <pid> --window-id <id>
          AOSComputerUseCLI stop-app-session
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
          AOSComputerUseCLI interactive

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
          start-app-session
                          Start a target app session; any different active session is stopped first.
          stop-app-session
                          Stop the active app session and run the core restore/deactivate path.
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
          interactive
                          Open a long-lived interactive command palette backed by one ComputerUseCore.
                          Use arrow keys to choose commands; Enter executes, Q exits.

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
        interactiveIO: InteractiveCLIIO = LiveInteractiveCLIIO(),
        windowOrderObserver: WindowOrderObservationClient = LiveWindowOrderObservationClient(),
        mouseEventObserver: MouseEventObservationClient = LiveMouseEventObservationClient()
    ) async throws -> ComputerUseCLIResult {
        try await run(
            arguments: arguments,
            core: core,
            appSessionPolicy: .oneShotEventCommands,
            permissions: permissions,
            coorTestTarget: coorTestTarget,
            postCursorIO: postCursorIO,
            postCursorOverlay: postCursorOverlay,
            interactiveIO: interactiveIO,
            windowOrderObserver: windowOrderObserver,
            mouseEventObserver: mouseEventObserver
        )
    }

    static func run(
        arguments: [String],
        core: ComputerUseCoreClient,
        appSessionPolicy: AppSessionPolicy,
        permissions: ComputerUsePermissionClient = LiveComputerUsePermissionClient(),
        coorTestTarget: CoorTestTargetClient = LiveCoorTestTargetClient(),
        postCursorIO: PostCursorIO = LivePostCursorIO(),
        postCursorOverlay: PostCursorOverlay = LivePostCursorOverlay(),
        interactiveIO: InteractiveCLIIO = LiveInteractiveCLIIO(),
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
            case .startAppSession(let request):
                let result = try await core.startAppSession(
                    pid: request.pid,
                    windowId: request.windowId
                )
                return try success(StartAppSessionOutput(result: result), format: parsed.outputFormat)
            case .stopAppSession:
                let result = try await core.stopAppSession()
                return try success(StopAppSessionOutput(result: result), format: parsed.outputFormat)
            case .mouseEventCommand(let request):
                try await requireSupportedMouseEventTarget(request: request, core: core)
                if request.trace {
                    let trace = try await runEventCommand(policy: appSessionPolicy, core: core) {
                        try await runMouseEventTraceCommand(request: request, core: core)
                    }
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
                let result = try await runEventCommand(policy: appSessionPolicy, core: core) {
                    try await runMouseEventCommand(request: request, core: core)
                }
                return try success(MouseEventPostOutput(request: request, result: result), format: parsed.outputFormat)
            case .keyboardEventCommand(let request):
                let result = try await runEventCommand(policy: appSessionPolicy, core: core) {
                    try await core.postKeyboardEvent(
                        pid: request.pid,
                        windowId: request.windowId,
                        event: request.event
                    )
                }
                return try success(KeyboardEventPostOutput(request: request, result: result), format: parsed.outputFormat)
            case .measureLeftClickWindowOrder(let request):
                let runs = try await runOneShotAppSessionCommand(core: core) {
                    try await measureLeftClickWindowOrder(
                        request: request,
                        core: core,
                        windowOrderObserver: windowOrderObserver
                    )
                }
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
                if appSessionPolicy == .oneShotEventCommands, result.postedEventCount > 0 {
                    _ = try await core.stopAppSession()
                }
                return try success(PostCursorOutput(result: result), format: parsed.outputFormat)
            case .interactive:
                try await runInteractiveSession(
                    core: core,
                    permissions: permissions,
                    coorTestTarget: coorTestTarget,
                    postCursorIO: postCursorIO,
                    postCursorOverlay: postCursorOverlay,
                    interactiveIO: interactiveIO,
                    windowOrderObserver: windowOrderObserver,
                    mouseEventObserver: mouseEventObserver
                )
                return ComputerUseCLIResult(stdout: "", stderr: "", exitCode: 0)
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

    static func requireWebContentDragTarget(
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

    static func leftClickPoint(from result: WindowMouseEventResult) throws -> CGPoint {
        guard case .click(.left, let point) = result.event else {
            throw ComputerUseCLIInvariantError("left-click diagnostic received \(result.event)")
        }
        return point
    }
}
