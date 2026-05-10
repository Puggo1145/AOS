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
                "--mode", "som",
                "--max-image-dimension", "1024"
            ],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.requestedStatePID == 123)
        #expect(await fake.requestedStateWindowID == 456)
        #expect(await fake.requestedCaptureMode == .som)
        #expect(await fake.requestedMaxImageDimension == 1024)
        #expect(result.stdout.contains("App State"))
        #expect(result.stdout.contains("state_123"))
        #expect(result.stdout.contains("AX elements: 1"))
        #expect(result.stdout.contains("Screenshot: png 10x20"))
        #expect(result.exitCode == 0)
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
}
