import AOSComputerUseKit
@testable import AOSComputerUseCLI
import CoreGraphics
import Foundation
import Testing

@Suite("AOSComputerUseCLI")
struct ComputerUseCLITests {
    @Test("help lists every supported command")
    func helpListsEveryCommand() throws {
        let output = try ComputerUseCLI.helpText()

        #expect(output.contains("list-apps"))
        #expect(output.contains("list-windows"))
        #expect(output.contains("get-app-state"))
        #expect(output.contains("focus-window"))
        #expect(output.contains("open-coor-test"))
        #expect(!output.contains("open-button"))
        #expect(output.contains("post-left-click"))
        #expect(output.contains("trace-postLeftClick"))
        #expect(output.contains("grant-permissions"))
        #expect(output.contains("--help"))
    }

    @Test("grant-permissions requests Accessibility and Screen Recording")
    func grantPermissionsRequestsRequiredPermissions() async throws {
        let permissions = FakePermissionClient()

        let result = try await ComputerUseCLI.run(
            arguments: ["grant-permissions"],
            core: FakeComputerUseCore(),
            permissions: permissions
        )

        #expect(await permissions.requested == [.accessibility, .screenRecording])
        #expect(result.stdout.contains("Permission Setup"))
        #expect(result.stdout.contains("Accessibility"))
        #expect(result.stdout.contains("Screen Recording"))
        #expect(result.exitCode == 0)
    }

    @Test("list-apps parses mode and emits human-readable output")
    func listAppsParsesModeAndEmitsHumanReadableOutput() async throws {
        let fake = FakeComputerUseCore()
        await fake.setApps([
            AppInfo(
                pid: 123,
                bundleId: "com.example.Terminal",
                name: "Terminal",
                path: "/Applications/Terminal.app",
                running: true,
                active: true
            )
        ])

        let result = try await ComputerUseCLI.run(
            arguments: ["list-apps", "--mode", "running"],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.requestedAppMode == .running)
        #expect(result.stdout.contains("Apps (running)"))
        #expect(result.stdout.contains("Terminal"))
        #expect(result.stdout.contains("pid 123"))
        #expect(result.stderr.isEmpty)
        #expect(result.exitCode == 0)
    }

    @Test("list-windows requires pid and emits window bounds")
    func listWindowsRequiresPidAndEmitsWindowBounds() async throws {
        let fake = FakeComputerUseCore()
        await fake.setWindows([
            WindowInfo(
                id: 456,
                pid: 123,
                owner: "Terminal",
                title: "Shell",
                bounds: WindowBounds(x: 1, y: 2, width: 800, height: 600),
                zIndex: 9,
                isOnScreen: true,
                layer: 0
            )
        ])

        let result = try await ComputerUseCLI.run(
            arguments: ["list-windows", "--pid", "123"],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.requestedWindowPID == 123)
        #expect(result.stdout.contains("Windows for pid 123"))
        #expect(result.stdout.contains("456"))
        #expect(result.stdout.contains("800x600"))
        #expect(result.exitCode == 0)
    }

    @Test("get-app-state parses capture mode and emits a readable state summary")
    func getAppStateParsesModeAndEmitsReadableStateSummary() async throws {
        let fake = FakeComputerUseCore()
        await fake.setState(AppStateBundle(
            stateId: StateID("state_123"),
            treeMarkdown: "[0] AXButton title=\"OK\"",
            elementCount: 1,
            screenshot: Screenshot(
                imageData: Data([1, 2, 3]),
                format: .png,
                width: 10,
                height: 20,
                scaleFactor: 2,
                coordinateSpace: ScreenshotCoordinateSpace(
                    windowFrame: WindowBounds(x: 0, y: 0, width: 5, height: 10),
                    pixelSize: CGSize(width: 10, height: 20)
                ),
                originalWidth: nil,
                originalHeight: nil
            ),
            bundleId: "com.example.Terminal",
            appName: "Terminal"
        ))

        let result = try await ComputerUseCLI.run(
            arguments: [
                "get-app-state",
                "--pid", "123",
                "--window-id", "456",
                "--mode", "vision",
                "--max-image-dimension", "1024"
            ],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.requestedStatePID == 123)
        #expect(await fake.requestedStateWindowID == 456)
        #expect(await fake.requestedCaptureMode == .vision)
        #expect(await fake.requestedMaxImageDimension == 1024)
        #expect(result.stdout.contains("App State"))
        #expect(result.stdout.contains("state_123"))
        #expect(result.stdout.contains("AX elements: 1"))
        #expect(result.stdout.contains("Screenshot: png 10x20"))
        #expect(result.exitCode == 0)
    }

    @Test("get-app-state vision mode still requires AX state in output")
    func getAppStateVisionModeIncludesAXState() async throws {
        let fake = FakeComputerUseCore()
        await fake.setState(AppStateBundle(
            stateId: StateID("state_vision"),
            treeMarkdown: "[0] AXButton title=\"OK\"",
            elementCount: 1,
            screenshot: nil,
            bundleId: "com.example.Terminal",
            appName: "Terminal"
        ))

        let result = try await ComputerUseCLI.run(
            arguments: [
                "get-app-state",
                "--pid", "123",
                "--window-id", "456",
                "--mode", "vision"
            ],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(result.stdout.contains("State ID: state_vision"))
        #expect(result.stdout.contains("AX elements: 1"))
        #expect(result.stdout.contains("AX Tree:"))
        #expect(result.stdout.contains("[0] AXButton"))
        #expect(!result.stdout.contains("AX elements: not captured"))
    }

    @Test("focus-window requires pid and window id")
    func focusWindowRequiresPidAndWindowID() async throws {
        let fake = FakeComputerUseCore()

        let result = try await ComputerUseCLI.run(
            arguments: ["focus-window", "--pid", "123", "--window-id", "456"],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.requestedFocusPID == 123)
        #expect(await fake.requestedFocusWindowID == 456)
        #expect(result.stdout.contains("Focused window 456 without raising it"))
        #expect(result.stderr.isEmpty)
        #expect(result.exitCode == 0)
    }

    @Test("post-left-click requires a local coordinate")
    func postLeftClickRequiresLocalCoordinate() async throws {
        let fake = FakeComputerUseCore()

        let result = try await ComputerUseCLI.run(
            arguments: ["post-left-click", "--pid", "123", "--window-id", "456"],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.requestedLeftClickPID == nil)
        #expect(await fake.requestedLeftClickWindowID == nil)
        #expect(result.stderr.contains("missing required option --coor"))
        #expect(result.exitCode != 0)
    }

    @Test("post-left-click accepts a local coordinate")
    func postLeftClickAcceptsLocalCoordinate() async throws {
        let fake = FakeComputerUseCore()
        await fake.setWindows([
            WindowInfo(
                id: 456,
                pid: 123,
                owner: "AOSCoordinateTarget",
                title: "AOS Button Reliability Target",
                bounds: WindowBounds(x: 50, y: 70, width: 520, height: 360),
                zIndex: 1,
                isOnScreen: true,
                layer: 0
            )
        ])

        let result = try await ComputerUseCLI.run(
            arguments: ["post-left-click", "--pid", "123", "--window-id", "456", "--coor", "260,180"],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.requestedWindowPID == 123)
        #expect(await fake.requestedLeftClickPID == 123)
        #expect(await fake.requestedLeftClickWindowID == 456)
        #expect(await fake.requestedLeftClickPoint == CGPoint(x: 310, y: 250))
        #expect(result.stdout.contains("Posted left click to window 456 at 310,250"))
        #expect(result.stderr.isEmpty)
        #expect(result.exitCode == 0)
    }

    @Test("postLeftClick camel-case command is not accepted")
    func postLeftClickCamelCaseCommandIsNotAccepted() async throws {
        let fake = FakeComputerUseCore()

        let result = try await ComputerUseCLI.run(
            arguments: ["postLeftClick", "--pid", "123", "--window-id", "456"],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.requestedLeftClickPID == nil)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("unknown command postLeftClick"))
        #expect(result.exitCode == 64)
    }

    @Test("open-coor-test starts the coordinate target")
    func openCoorTestStartsCoordinateTarget() async throws {
        let target = FakeCoorTestTargetClient()

        let result = try await ComputerUseCLI.run(
            arguments: ["open-coor-test"],
            core: FakeComputerUseCore(),
            permissions: FakePermissionClient(),
            coorTestTarget: target
        )

        #expect(await target.opened == true)
        #expect(result.stdout.contains("Coordinate click test target opened"))
        #expect(result.stdout.contains("pid 777"))
        #expect(result.stdout.contains("window 888"))
        #expect(result.exitCode == 0)
    }

    @Test("trace-postLeftClick requires pid and window id")
    func tracePostLeftClickRequiresPidAndWindowID() async throws {
        let fake = FakeComputerUseCore()

        let result = try await ComputerUseCLI.run(
            arguments: ["trace-postLeftClick", "--pid", "123", "--window-id", "456", "--skip-focus"],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.requestedTraceLeftClickPID == 123)
        #expect(await fake.requestedTraceLeftClickWindowID == 456)
        #expect(await fake.requestedTraceLeftClickSkipFocus == true)
        #expect(result.stdout.contains("Left Click Trace"))
        #expect(result.stdout.contains("Focus: skipped"))
        #expect(result.stdout.contains("afterTargetUp"))
        #expect(result.stderr.isEmpty)
        #expect(result.exitCode == 0)
    }

    @Test("json flag keeps machine-readable output")
    func jsonFlagKeepsMachineReadableOutput() async throws {
        let fake = FakeComputerUseCore()
        await fake.setApps([
            AppInfo(
                pid: 123,
                bundleId: "com.example.Terminal",
                name: "Terminal",
                path: "/Applications/Terminal.app",
                running: true,
                active: true
            )
        ])

        let result = try await ComputerUseCLI.run(
            arguments: ["list-apps", "--mode", "running", "--json"],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(result.stdout.contains("\"command\":\"list-apps\""))
        #expect(result.stdout.contains("\"name\":\"Terminal\""))
        #expect(result.exitCode == 0)
    }

    @Test("missing required option returns usage error")
    func missingRequiredOptionReturnsUsageError() async throws {
        let result = try await ComputerUseCLI.run(
            arguments: ["list-windows"],
            core: FakeComputerUseCore(),
            permissions: FakePermissionClient()
        )

        #expect(result.exitCode == 64)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("missing required option --pid"))
    }
}

private actor FakePermissionClient: ComputerUsePermissionClient {
    private(set) var requested: [ComputerUsePermission] = []

    func request(_ permissions: [ComputerUsePermission]) async throws -> PermissionGrantResult {
        requested = permissions
        return PermissionGrantResult(
            requested: permissions,
            status: [
                .accessibility: true,
                .screenRecording: false,
            ],
            guidance: [
                "Accessibility: grant this terminal app in System Settings.",
                "Screen Recording: grant this terminal app in System Settings.",
            ]
        )
    }
}

private actor FakeCoorTestTargetClient: CoorTestTargetClient {
    private(set) var opened = false
    var state = CoorTestTargetState(
        pid: 777,
        windowId: 888,
        eventLogPath: "/tmp/aos-coordinate-events.jsonl"
    )

    func open() async throws -> CoorTestTargetState {
        opened = true
        return state
    }
}

private actor FakeComputerUseCore: ComputerUseCoreClient {
    var apps: [AppInfo] = []
    var windows: [WindowInfo] = []
    var state: AppStateBundle?

    private(set) var requestedAppMode: AppListMode?
    private(set) var requestedWindowPID: pid_t?
    private(set) var requestedStatePID: pid_t?
    private(set) var requestedStateWindowID: CGWindowID?
    private(set) var requestedCaptureMode: CaptureMode?
    private(set) var requestedMaxImageDimension: Int?
    private(set) var requestedFocusPID: pid_t?
    private(set) var requestedFocusWindowID: CGWindowID?
    private(set) var requestedLeftClickPID: pid_t?
    private(set) var requestedLeftClickWindowID: CGWindowID?
    private(set) var requestedLeftClickPoint: CGPoint?
    private(set) var requestedTraceLeftClickPID: pid_t?
    private(set) var requestedTraceLeftClickWindowID: CGWindowID?
    private(set) var requestedTraceLeftClickSkipFocus: Bool?
    private(set) var requestedTraceLeftClickOverridePoint: CGPoint?

    func setApps(_ apps: [AppInfo]) {
        self.apps = apps
    }

    func setWindows(_ windows: [WindowInfo]) {
        self.windows = windows
    }

    func setState(_ state: AppStateBundle) {
        self.state = state
    }

    func listApps(mode: AppListMode) async throws -> [AppInfo] {
        requestedAppMode = mode
        return apps
    }

    func listWindows(pid: pid_t) async throws -> [WindowInfo] {
        requestedWindowPID = pid
        return windows
    }

    func getAppState(
        pid: pid_t,
        windowId: CGWindowID,
        captureMode: CaptureMode,
        maxImageDimension: Int
    ) async throws -> AppStateBundle {
        requestedStatePID = pid
        requestedStateWindowID = windowId
        requestedCaptureMode = captureMode
        requestedMaxImageDimension = maxImageDimension
        return try #require(state)
    }

    func focusWindowWithoutRaise(pid: pid_t, windowId: CGWindowID) async throws -> WindowFocusResult {
        requestedFocusPID = pid
        requestedFocusWindowID = windowId
        return WindowFocusResult(pid: pid, windowId: windowId)
    }

    func postLeftClick(pid: pid_t, windowId: CGWindowID, point: CGPoint) async throws -> WindowClickResult {
        requestedLeftClickPID = pid
        requestedLeftClickWindowID = windowId
        requestedLeftClickPoint = point
        return WindowClickResult(pid: pid, windowId: windowId, point: point)
    }

    func tracePostLeftClick(
        pid: pid_t,
        windowId: CGWindowID,
        skipFocus: Bool,
        overridePoint: CGPoint?
    ) async throws -> WindowClickTraceResult {
        requestedTraceLeftClickPID = pid
        requestedTraceLeftClickWindowID = windowId
        requestedTraceLeftClickSkipFocus = skipFocus
        requestedTraceLeftClickOverridePoint = overridePoint
        return WindowClickTraceResult(
            pid: pid,
            windowId: windowId,
            point: CGPoint(x: 10, y: 20),
            samples: [
                WindowOrderSnapshot(
                    stage: .before,
                    frontmostPid: 999,
                    frontmostBundleId: "com.example.Front",
                    frontmostName: "Front",
                    targetRank: 3,
                    targetZIndex: 7,
                    windowsAboveTarget: 2,
                    overlappingWindowsAboveTarget: 1,
                    protectedOverlappingWindowsCoveredByTarget: 0,
                    topWindows: []
                ),
                WindowOrderSnapshot(
                    stage: .afterTargetUp,
                    frontmostPid: 999,
                    frontmostBundleId: "com.example.Front",
                    frontmostName: "Front",
                    targetRank: 3,
                    targetZIndex: 7,
                    windowsAboveTarget: 2,
                    overlappingWindowsAboveTarget: 1,
                    protectedOverlappingWindowsCoveredByTarget: 0,
                    topWindows: []
                ),
            ]
        )
    }
}
