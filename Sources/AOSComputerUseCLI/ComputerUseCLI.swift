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
          AOSComputerUseCLI interactive

        Commands:
          interactive
                          Open a long-lived interactive command palette backed by one ComputerUseCore.
                          All Computer Use commands run inside that stateful core.

        Output:
          Standalone command execution has been removed. Run interactive mode.
        """
    }

    public static func run(
        arguments: [String],
        core: ComputerUseCoreClient,
        permissions: ComputerUsePermissionClient = LiveComputerUsePermissionClient(),
        coorTestTarget: CoorTestTargetClient? = nil,
        postCursorIO: PostCursorIO = LivePostCursorIO(),
        postCursorOverlay: PostCursorOverlay = LivePostCursorOverlay(),
        interactiveIO: InteractiveCLIIO = LiveInteractiveCLIIO(),
        windowOrderObserver: WindowOrderObservationClient? = nil,
        mouseEventObserver: MouseEventObservationClient = LiveMouseEventObservationClient()
    ) async throws -> ComputerUseCLIResult {
        do {
            let parsed = try ParsedCommand(arguments: arguments)
            let coorTestTarget = coorTestTarget ?? LiveCoorTestTargetClient(core: core)
            let windowOrderObserver = windowOrderObserver
                ?? LiveWindowOrderObservationClient(diagnostics: core.diagnosticsClient)
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
                    windowId: request.windowId,
                    captureMode: request.captureMode
                )
                if let outputPath = request.screenshotOutput,
                   let screenshot = state.screenshot {
                    try screenshot.imageData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
                }
                return try success(AppStateOutput(request: request, state: state), format: parsed.outputFormat)
            case .focusWindow(let request):
                let result = try await core.diagnosticsClient.focusWindowWithoutRaise(
                    pid: request.pid,
                    windowId: request.windowId
                )
                return try success(FocusWindowOutput(request: request, result: result), format: parsed.outputFormat)
            case .startAppSession(let request):
                let result = try await core.startAppSession(
                    pid: request.pid,
                    windowId: request.windowId
                )
                return try success(StartAppSessionOutput(request: request, result: result), format: parsed.outputFormat)
            case .stopAppSession:
                let result = try await core.stopAppSession()
                return try success(StopAppSessionOutput(result: result), format: parsed.outputFormat)
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
                    windowId: request.windowId,
                    event: request.event
                )
                return try success(KeyboardEventPostOutput(request: request, result: result), format: parsed.outputFormat)
            case .axElementEventCommand(let request):
                let result = try await core.postEventToAXElement(
                    windowId: request.windowId,
                    stateId: request.stateId,
                    elementIndex: request.elementIndex,
                    event: request.event
                )
                return try success(AXElementEventPostOutput(request: request, result: result), format: parsed.outputFormat)
            case .measureLeftClickWindowOrder(let request):
                let session = try await core.currentAppSession()
                let runs = try await measureLeftClickWindowOrder(
                    request: request,
                    activePID: session.pid,
                    core: core,
                    windowOrderObserver: windowOrderObserver
                )
                return try success(
                    LeftClickWindowOrderMeasurementOutput(request: request, pid: session.pid, runs: runs),
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
        let session = try await core.currentAppSession()
        try await requireWebContentDragTarget(pid: session.pid, core: core)
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
        activePID: pid_t,
        core: ComputerUseCoreClient,
        windowOrderObserver: WindowOrderObservationClient
    ) async throws -> [LeftClickWindowOrderMeasurementRun] {
        let screenPoint = try await screenPoint(
            windowId: request.windowId,
            coordinate: request.coordinate,
            core: core
        )
        var runs: [LeftClickWindowOrderMeasurementRun] = []
        for runIndex in 1...request.runs {
            let orderRequest = WindowOrderObservationRequest(
                pid: activePID,
                windowId: request.windowId,
                durationMilliseconds: request.durationMilliseconds,
                intervalMilliseconds: request.intervalMilliseconds
            )
            async let observedSamples = windowOrderObserver.observe(orderRequest)
            await Task.yield()
            try await sleep(milliseconds: request.preClickDelayMilliseconds)
            let click = try await core.postMouseEvent(
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
        return try await core.diagnosticsClient.postMouseEventTrace(
            windowId: request.windowId,
            event: event
        )
    }

    private static func backgroundMouseEvent(
        request: MouseEventCommandRequest,
        core: ComputerUseCoreClient
    ) async throws -> BackgroundMouseEvent {
        switch request.event {
        case .click(let button, let coordinate, let count):
            return try await .click(
                button: button,
                point: screenPoint(windowId: request.windowId, coordinate: coordinate, core: core),
                count: count
            )
        case .drag(let button, let start, let end):
            return try await .drag(
                button: button,
                from: screenPoint(windowId: request.windowId, coordinate: start, core: core),
                to: screenPoint(windowId: request.windowId, coordinate: end, core: core)
            )
        }
    }

    private static func screenPoint(
        windowId: CGWindowID,
        coordinate: CGPoint,
        core: ComputerUseCoreClient
    ) async throws -> CGPoint {
        let session = try await core.currentAppSession()
        let pid = session.pid
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
        guard case .click(.left, let point, _) = result.event else {
            throw ComputerUseCLIInvariantError("left-click diagnostic received \(result.event)")
        }
        return point
    }
}
