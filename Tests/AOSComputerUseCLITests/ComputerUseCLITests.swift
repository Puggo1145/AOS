import AOSComputerUseKit
@testable import AOSComputerUseCLI
import CoreGraphics
import Foundation
import Testing

@Suite("AOSComputerUseCLI")
struct ComputerUseCLITests {
    @Test("help exposes only the interactive executable entrypoint")
    func helpExposesOnlyInteractiveExecutableEntrypoint() throws {
        let output = try ComputerUseCLI.helpText()

        #expect(output.contains("interactive"))
        #expect(output.contains("Standalone command execution has been removed"))
        #expect(!output.contains("grant-permissions"))
        #expect(!output.contains("list-apps [--mode"))
        #expect(!output.contains("left-click --window-id"))
        #expect(output.contains("--help"))
    }

    @Test("executable rejects standalone commands")
    func executableRejectsStandaloneCommands() async {
        let result = await AOSComputerUseCLIExecutable.run(arguments: ["list-apps"])

        #expect(result.exitCode == 64)
        #expect(result.stderr.contains("standalone commands were removed"))
        #expect(result.stderr.contains("AOSComputerUseCLI interactive"))
    }

    @Test("executable accepts short help")
    func executableAcceptsShortHelp() async {
        let result = await AOSComputerUseCLIExecutable.run(arguments: ["-h"])

        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("AOSComputerUseCLI interactive"))
        #expect(result.stderr.isEmpty)
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

    @Test("get-app-type emits AOS app classification for a pid")
    func getAppTypeEmitsClassificationForPID() async throws {
        let fake = FakeComputerUseCore()
        await fake.setAppType(AppTypeResult(
            pid: 123,
            appName: "NetEaseMusic",
            bundleId: "com.netease.163music",
            bundlePath: "/Applications/NeteaseMusic.app",
            type: .webContent,
            reason: .chromiumEmbeddedFramework
        ))

        let result = try await ComputerUseCLI.run(
            arguments: ["get-app-type", "--pid", "123"],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.requestedAppTypePID == 123)
        #expect(result.stdout.contains("App type for pid 123"))
        #expect(result.stdout.contains("name: NetEaseMusic"))
        #expect(result.stdout.contains("bundleId: com.netease.163music"))
        #expect(result.stdout.contains("type: webContent"))
        #expect(result.stdout.contains("reason: chromiumEmbeddedFramework"))
        #expect(result.stdout.contains("bundlePath: /Applications/NeteaseMusic.app"))
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

    @Test("start-app-session starts target app session")
    func startAppSessionStartsTargetAppSession() async throws {
        let fake = FakeComputerUseCore()

        let result = try await ComputerUseCLI.run(
            arguments: ["start-app-session", "--pid", "123", "--window-id", "456"],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.requestedStartAppSessionPID == 123)
        #expect(await fake.requestedStartAppSessionWindowID == 456)
        #expect(result.stdout.contains("Started app session for pid 123, focused window 456"))
        #expect(result.stdout.contains("pid 123"))
        #expect(result.stderr.isEmpty)
        #expect(result.exitCode == 0)
    }

    @Test("stop-app-session stops active app session")
    func stopAppSessionStopsActiveAppSession() async throws {
        let fake = FakeComputerUseCore()
        await fake.setStoppedAppSession(AppSessionResult(pid: 123))

        let result = try await ComputerUseCLI.run(
            arguments: ["stop-app-session"],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.stopAppSessionCallCount == 1)
        #expect(result.stdout.contains("Stopped app session for pid 123"))
        #expect(result.stdout.contains("pid 123"))
        #expect(result.stderr.isEmpty)
        #expect(result.exitCode == 0)
    }

    @Test("interactive CLI uses arrow selection and reuses one core")
    func interactiveCLIUsesArrowSelectionAndReusesOneCore() async throws {
        let fake = FakeComputerUseCore()
        await fake.setApps([
            AppInfo(
                pid: 111,
                bundleId: "com.example.Other",
                name: "Other",
                path: "/Applications/Other.app",
                running: true,
                active: false
            ),
            AppInfo(
                pid: 123,
                bundleId: "com.example.Target",
                name: "Target",
                path: "/Applications/Target.app",
                running: true,
                active: false
            ),
        ])
        await fake.setWindows([
            WindowInfo(
                id: 222,
                pid: 123,
                owner: "Target",
                title: "Aux",
                bounds: WindowBounds(x: 0, y: 0, width: 100, height: 100),
                zIndex: 2,
                isOnScreen: true,
                layer: 0
            ),
            WindowInfo(
                id: 456,
                pid: 123,
                owner: "Target",
                title: "Main",
                bounds: WindowBounds(x: 10, y: 20, width: 500, height: 400),
                zIndex: 1,
                isOnScreen: true,
                layer: 0
            ),
        ])
        await fake.setStoppedAppSession(AppSessionResult(pid: 123))
        let io = FakeInteractiveCLIIO(
            lines: [],
            keys: [
                .confirm,
                .down, .confirm,
                .down, .confirm,
                .down, .confirm,
                .quit,
            ]
        )

        let result = try await ComputerUseCLI.run(
            arguments: ["interactive"],
            core: fake,
            permissions: FakePermissionClient(),
            interactiveIO: io
        )

        #expect(await fake.requestedStartAppSessionPID == 123)
        #expect(await fake.requestedStartAppSessionWindowID == 456)
        #expect(await fake.stopAppSessionCallCount == 1)
        #expect(await io.prompts.isEmpty)
        #expect(await io.output.isEmpty)
        #expect(await io.status.contains { $0.contains("Output") && $0.contains("Started app session for pid 123, focused window 456") })
        #expect(await io.status.contains { $0.contains("Output") && $0.contains("Stopped app session for pid 123") })
        #expect(await io.status.contains { $0.contains("> start-app-session") })
        #expect(await io.status.contains { $0.contains("> Target pid 123") })
        #expect(await io.status.contains { $0.contains("> 456 Main") })
        #expect(await io.status.contains { $0.contains("> stop-app-session") })
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.isEmpty)
        #expect(result.exitCode == 0)
    }

    @Test("interactive CLI stops an active app session on exit")
    func interactiveCLIStopsActiveAppSessionOnExit() async throws {
        let fake = FakeComputerUseCore()
        await fake.setApps([
            AppInfo(
                pid: 123,
                bundleId: "com.example.Target",
                name: "Target",
                path: "/Applications/Target.app",
                running: true,
                active: false
            ),
        ])
        await fake.setWindows([
            WindowInfo(
                id: 456,
                pid: 123,
                owner: "Target",
                title: "Main",
                bounds: WindowBounds(x: 10, y: 20, width: 500, height: 400),
                zIndex: 1,
                isOnScreen: true,
                layer: 0
            ),
        ])
        let io = FakeInteractiveCLIIO(
            keys: [
                .confirm,
                .confirm,
                .confirm,
                .quit,
            ]
        )

        let result = try await ComputerUseCLI.run(
            arguments: ["interactive"],
            core: fake,
            permissions: FakePermissionClient(),
            interactiveIO: io
        )

        #expect(await fake.requestedStartAppSessionPID == 123)
        #expect(await fake.requestedStartAppSessionWindowID == 456)
        #expect(await fake.stopAppSessionCallCount == 1)
        #expect(result.exitCode == 0)
    }

    @Test("interactive CLI stops an active app session when the command loop throws")
    func interactiveCLIStopsActiveAppSessionWhenCommandLoopThrows() async throws {
        let fake = FakeComputerUseCore()
        await fake.setApps([
            AppInfo(
                pid: 123,
                bundleId: "com.example.Target",
                name: "Target",
                path: "/Applications/Target.app",
                running: true,
                active: false
            ),
        ])
        await fake.setWindows([
            WindowInfo(
                id: 456,
                pid: 123,
                owner: "Target",
                title: "Main",
                bounds: WindowBounds(x: 10, y: 20, width: 500, height: 400),
                zIndex: 1,
                isOnScreen: true,
                layer: 0
            ),
        ])
        let io = FakeInteractiveCLIIO(
            keys: [
                .confirm,
                .confirm,
                .confirm,
            ],
            throwsWhenKeysAreExhausted: true
        )

        let result = try await ComputerUseCLI.run(
            arguments: ["interactive"],
            core: fake,
            permissions: FakePermissionClient(),
            interactiveIO: io
        )

        #expect(await fake.requestedStartAppSessionPID == 123)
        #expect(await fake.requestedStartAppSessionWindowID == 456)
        #expect(await fake.stopAppSessionCallCount == 1)
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("fake interactive key queue exhausted"))
    }

    @Test("interactive selection menu redraws and clears its terminal region")
    func interactiveSelectionMenuRedrawsAndClearsRegion() async throws {
        let io = FakeInteractiveCLIIO(keys: [.down, .confirm])
        let menu = InteractiveSelectionMenu(
            title: "Command",
            options: [
                InteractiveSelectionOption(title: "first", value: 1),
                InteractiveSelectionOption(title: "second", value: 2),
            ]
        )

        let selected = try await menu.select(using: io)

        let status = await io.status.joined()
        #expect(selected == 2)
        #expect(status.contains("\u{001B}[5A"))
        #expect(status.contains("\u{001B}[2K"))
        #expect(status.hasSuffix("\u{001B}[5A\u{001B}[2K\u{001B}[1B\u{001B}[2K\u{001B}[1B\u{001B}[2K\u{001B}[1B\u{001B}[2K\u{001B}[1B\u{001B}[2K\u{001B}[1B\u{001B}[5A"))
    }

    @Test("interactive selection menu renders a scrolling viewport")
    func interactiveSelectionMenuRendersScrollingViewport() async throws {
        let io = FakeInteractiveCLIIO(keys: Array(repeating: .down, count: 8) + [.confirm])
        let menu = InteractiveSelectionMenu(
            title: "Command",
            options: (0..<12).map {
                InteractiveSelectionOption(title: "item-\($0)", value: $0)
            }
        )

        let selected = try await menu.select(using: io)

        let firstRender = try #require(await io.status.first)
        let renderAfterScroll = try #require(await io.status.last { $0.contains("> item-8") })
        #expect(selected == 8)
        #expect(firstRender.contains("Command\n-------"))
        #expect(firstRender.contains("Showing 1-8 of 12"))
        #expect(firstRender.contains("> item-0"))
        #expect(firstRender.contains("  item-7"))
        #expect(!firstRender.contains("item-8"))
        #expect(renderAfterScroll.contains("Showing 2-9 of 12"))
        #expect(renderAfterScroll.contains("> item-8"))
        #expect(!renderAfterScroll.contains("item-0"))
    }

    @Test("interactive prompt input is cleared before rendering errors")
    func interactivePromptInputIsClearedBeforeRenderingErrors() async throws {
        let fake = FakeComputerUseCore()
        await fake.setApps([
            AppInfo(
                pid: 123,
                bundleId: "com.example.Target",
                name: "Target",
                path: "/Applications/Target.app",
                running: true,
                active: false
            ),
        ])
        await fake.setWindows([
            WindowInfo(
                id: 456,
                pid: 123,
                owner: "Target",
                title: "Main",
                bounds: WindowBounds(x: 10, y: 20, width: 500, height: 400),
                zIndex: 1,
                isOnScreen: true,
                layer: 0
            ),
        ])
        let io = FakeInteractiveCLIIO(
            lines: ["q", ""],
            keys: Array(repeating: .down, count: 7) + [.confirm, .confirm, .confirm, .quit]
        )

        let result = try await ComputerUseCLI.run(
            arguments: ["interactive"],
            core: fake,
            permissions: FakePermissionClient(),
            interactiveIO: io
        )

        #expect(await io.status.contains("\u{001B}[1A\u{001B}[2K"))
        #expect(await io.status.contains { $0.contains("Error") && $0.contains("invalid value for --coor: q") })
        #expect(result.exitCode == 0)
    }

    @Test("interactive command menu accepts typed prefix matching")
    func interactiveCommandMenuAcceptsTypedPrefixMatching() async throws {
        let fake = FakeComputerUseCore()
        await fake.setApps([
            AppInfo(
                pid: 123,
                bundleId: "com.example.Target",
                name: "Target",
                path: "/Applications/Target.app",
                running: true,
                active: false
            ),
        ])
        let io = FakeInteractiveCLIIO(keys: [
            .character("l"),
            .character("i"),
            .confirm,
            .confirm,
            .quit,
        ])

        let result = try await ComputerUseCLI.run(
            arguments: ["interactive"],
            core: fake,
            permissions: FakePermissionClient(),
            interactiveIO: io
        )

        #expect(await fake.requestedAppMode == .running)
        #expect(await io.status.contains { $0.contains("Prefix: li") && $0.contains("> list-apps") })
        #expect(await io.status.contains { $0.contains("Output") && $0.contains("Apps (running)") })
        #expect(result.exitCode == 0)
    }

    @Test("interactive post-cursor always selects a target")
    func interactivePostCursorAlwaysSelectsTarget() async throws {
        let fake = FakeComputerUseCore()
        await fake.setApps([
            AppInfo(
                pid: 123,
                bundleId: "com.example.Target",
                name: "Target",
                path: "/Applications/Target.app",
                running: true,
                active: false
            ),
        ])
        await fake.setWindows([
            WindowInfo(
                id: 456,
                pid: 123,
                owner: "Target",
                title: "Main",
                bounds: WindowBounds(x: 10, y: 20, width: 500, height: 400),
                zIndex: 1,
                isOnScreen: true,
                layer: 0
            ),
        ])
        let interactiveIO = FakeInteractiveCLIIO(
            lines: [""],
            keys: [
                .character("p"),
                .character("o"),
                .confirm,
                .confirm,
                .quit,
            ]
        )
        let postCursorIO = FakePostCursorIO(lines: ["left-click"], keys: [.quit])

        let result = try await ComputerUseCLI.run(
            arguments: ["interactive"],
            core: fake,
            permissions: FakePermissionClient(),
            postCursorIO: postCursorIO,
            postCursorOverlay: FakePostCursorOverlay(),
            interactiveIO: interactiveIO
        )

        #expect(await fake.requestedWindowPID == 123)
        #expect(await interactiveIO.status.contains { $0.contains("> 456 Main") })
        #expect(await !interactiveIO.status.contains { $0.contains("Attach to a target now?") })
        #expect(await postCursorIO.prompts == ["Select mouse event (left-click/right-click/drag): "])
        #expect(result.exitCode == 0)
    }

    @Test("interactive post-ax-event posts through the command palette")
    func interactivePostAXEventPostsThroughCommandPalette() async throws {
        let fake = FakeComputerUseCore()
        await fake.setApps([
            AppInfo(
                pid: 123,
                bundleId: "com.example.Target",
                name: "Target",
                path: "/Applications/Target.app",
                running: true,
                active: false
            ),
        ])
        await fake.setWindows([
            WindowInfo(
                id: 456,
                pid: 123,
                owner: "Target",
                title: "Main",
                bounds: WindowBounds(x: 10, y: 20, width: 500, height: 400),
                zIndex: 1,
                isOnScreen: true,
                layer: 0
            ),
        ])
        let io = FakeInteractiveCLIIO(
            lines: ["state_abc", "7"],
            keys: [
                .character("p"), .character("o"), .character("s"), .character("t"), .character("-"), .character("a"),
                .confirm,
                .confirm,
                .confirm,
                .confirm,
                .confirm,
                .quit,
            ]
        )

        let result = try await ComputerUseCLI.run(
            arguments: ["interactive"],
            core: fake,
            permissions: FakePermissionClient(),
            interactiveIO: io
        )

        #expect(await fake.requestedAXEventPID == 123)
        #expect(await fake.requestedAXEventWindowID == 456)
        #expect(await fake.requestedAXEventStateID == StateID("state_abc"))
        #expect(await fake.requestedAXEventElementIndex == 7)
        #expect(await fake.requestedAXEvent == .action(.press))
        #expect(await io.status.contains { $0.contains("Prefix: post-a") && $0.contains("> post-ax-event") })
        #expect(result.exitCode == 0)
    }

    @Test("left-click requires a local coordinate")
    func leftClickRequiresLocalCoordinate() async throws {
        let fake = FakeComputerUseCore()

        let result = try await ComputerUseCLI.run(
            arguments: ["left-click", "--window-id", "456"],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.requestedLeftClickPID == nil)
        #expect(await fake.requestedLeftClickWindowID == nil)
        #expect(result.stderr.contains("missing required option --coor"))
        #expect(result.exitCode != 0)
    }

    @Test("left-click accepts a local coordinate")
    func leftClickAcceptsLocalCoordinate() async throws {
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
            arguments: ["left-click", "--window-id", "456", "--coor", "260,180"],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.requestedWindowPID == 123)
        #expect(await fake.requestedLeftClickPID == 123)
        #expect(await fake.requestedLeftClickTracePID == nil)
        #expect(await fake.requestedLeftClickWindowID == 456)
        #expect(await fake.requestedLeftClickPoint == CGPoint(x: 310, y: 250))
        #expect(await fake.stopAppSessionCallCount == 0)
        #expect(result.stdout.contains("Posted left click to window 456 at 310,250"))
        #expect(result.stderr.isEmpty)
        #expect(result.exitCode == 0)
    }

    @Test("left-click parses count")
    func leftClickParsesCount() async throws {
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
            arguments: ["left-click", "--window-id", "456", "--coor", "260,180", "--count", "2"],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.requestedMouseEvent == .click(
            button: .left,
            point: CGPoint(x: 310, y: 250),
            count: 2
        ))
        #expect(result.stderr.isEmpty)
        #expect(result.exitCode == 0)
    }

    @Test("event command keeps the app session open")
    func eventCommandKeepsTheAppSessionOpen() async throws {
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
            arguments: ["left-click", "--window-id", "456", "--coor", "260,180"],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.requestedLeftClickPID == 123)
        #expect(await fake.stopAppSessionCallCount == 0)
        #expect(result.stdout.contains("Posted left click to window 456 at 310,250"))
        #expect(result.stderr.isEmpty)
        #expect(result.exitCode == 0)
    }

    @Test("right-click accepts a local coordinate")
    func rightClickAcceptsLocalCoordinate() async throws {
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
            arguments: ["right-click", "--window-id", "456", "--coor", "260,180"],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.requestedMouseEvent == .click(button: .right, point: CGPoint(x: 310, y: 250)))
        #expect(await fake.stopAppSessionCallCount == 0)
        #expect(result.stdout.contains("Posted right click to window 456 at 310,250"))
        #expect(result.stderr.isEmpty)
        #expect(result.exitCode == 0)
    }

    @Test("right-click parses count")
    func rightClickParsesCount() async throws {
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
            arguments: ["right-click", "--window-id", "456", "--coor", "260,180", "--count", "3"],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.requestedMouseEvent == .click(
            button: .right,
            point: CGPoint(x: 310, y: 250),
            count: 3
        ))
        #expect(result.stderr.isEmpty)
        #expect(result.exitCode == 0)
    }

    @Test("left-click rejects zero count")
    func leftClickRejectsZeroCount() async throws {
        let fake = FakeComputerUseCore()

        let result = try await ComputerUseCLI.run(
            arguments: ["left-click", "--window-id", "456", "--coor", "260,180", "--count", "0"],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.requestedMouseEvent == nil)
        #expect(result.stderr.contains("invalid value for --count: 0"))
        #expect(result.exitCode != 0)
    }

    @Test("scroll command is not accepted")
    func scrollCommandIsNotAccepted() async throws {
        let fake = FakeComputerUseCore()

        let result = try await ComputerUseCLI.run(
            arguments: ["scroll", "--pid", "123", "--window-id", "456", "--coor", "260,180", "--delta", "-12,24"],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.requestedMouseEvent == nil)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("unknown command scroll"))
        #expect(result.exitCode == 64)
    }

    @Test("drag accepts local endpoints and button")
    func dragAcceptsLocalEndpointsAndButton() async throws {
        let fake = FakeComputerUseCore()
        await fake.setAppType(AppTypeResult(
            pid: 123,
            appName: "Chrome",
            bundleId: "com.google.Chrome",
            bundlePath: "/Applications/Google Chrome.app",
            type: .webContent,
            reason: .chromiumBrowserBundleId
        ))
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
            arguments: [
                "drag",
                "--window-id", "456",
                "--from", "260,180",
                "--to", "280,210",
                "--button", "right",
            ],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.requestedMouseEvent == .drag(
            button: .right,
            from: CGPoint(x: 310, y: 250),
            to: CGPoint(x: 330, y: 280)
        ))
        #expect(await fake.requestedAppTypePID == 123)
        #expect(await fake.stopAppSessionCallCount == 0)
        #expect(result.stdout.contains("Posted right drag to window 456 from 310,250 to 330,280"))
        #expect(result.stderr.isEmpty)
        #expect(result.exitCode == 0)
    }

    @Test("drag rejects AppKit targets before posting")
    func dragRejectsAppKitTargetsBeforePosting() async throws {
        let fake = FakeComputerUseCore()
        await fake.setAppType(AppTypeResult(
            pid: 123,
            appName: "Finder",
            bundleId: "com.apple.finder",
            bundlePath: "/System/Library/CoreServices/Finder.app",
            type: .appKit,
            reason: .appKitDefault
        ))

        let result = try await ComputerUseCLI.run(
            arguments: [
                "drag",
                "--window-id", "456",
                "--from", "260,180",
                "--to", "280,210",
            ],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.requestedAppTypePID == 123)
        #expect(await fake.requestedWindowPID == nil)
        #expect(await fake.requestedMouseEvent == nil)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("drag is only supported for web-content targets"))
        #expect(result.stderr.contains("Finder"))
        #expect(result.exitCode == 64)
    }

    @Test("type-text posts keyboard text event")
    func typeTextPostsKeyboardTextEvent() async throws {
        let fake = FakeComputerUseCore()

        let result = try await ComputerUseCLI.run(
            arguments: [
                "type-text",
                "--window-id", "456",
                "--text", "hello",
                "--delay-ms", "40",
            ],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.requestedKeyboardEvent == .text("hello", delayMilliseconds: 40))
        #expect(await fake.stopAppSessionCallCount == 0)
        #expect(result.stdout.contains("Posted keyboard event text input 5 character(s) delay 40ms"))
        #expect(result.exitCode == 0)
    }

    @Test("hotkey parses modifier aliases and final key")
    func hotkeyParsesModifierAliasesAndFinalKey() async throws {
        let fake = FakeComputerUseCore()

        let result = try await ComputerUseCLI.run(
            arguments: [
                "hotkey",
                "--window-id", "456",
                "--keys", "cmd,shift,s",
            ],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.requestedKeyboardEvent == .hotkey(modifiers: [.command, .shift], key: "s"))
        #expect(await fake.stopAppSessionCallCount == 0)
        #expect(result.stdout.contains("Posted keyboard event command+shift+s"))
        #expect(result.exitCode == 0)
    }

    @Test("press-key parses count")
    func pressKeyParsesCount() async throws {
        let fake = FakeComputerUseCore()

        let result = try await ComputerUseCLI.run(
            arguments: [
                "press-key",
                "--window-id", "456",
                "--key", "delete",
                "--count", "5",
            ],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.requestedKeyboardEvent == .keyPress(key: "delete", count: 5))
        #expect(await fake.stopAppSessionCallCount == 0)
        #expect(result.stdout.contains("Posted keyboard event delete x5"))
        #expect(result.exitCode == 0)
    }

    @Test("post-ax-event posts an AX action by state element index")
    func postAXEventPostsActionByStateElementIndex() async throws {
        let fake = FakeComputerUseCore()

        let result = try await ComputerUseCLI.run(
            arguments: [
                "post-ax-event",
                "--pid", "123",
                "--window-id", "456",
                "--state-id", "state_abc",
                "--element-index", "7",
                "--action", "press",
            ],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.requestedAXEventPID == 123)
        #expect(await fake.requestedAXEventWindowID == 456)
        #expect(await fake.requestedAXEventStateID == StateID("state_abc"))
        #expect(await fake.requestedAXEventElementIndex == 7)
        #expect(await fake.requestedAXEvent == .action(.press))
        #expect(result.stdout.contains("Posted AX element event press"))
        #expect(result.stdout.contains("element 7"))
        #expect(result.exitCode == 0)
    }

    @Test("post-ax-event parses semantic scroll pages")
    func postAXEventParsesSemanticScrollPages() async throws {
        let fake = FakeComputerUseCore()

        let result = try await ComputerUseCLI.run(
            arguments: [
                "post-ax-event",
                "--pid", "123",
                "--window-id", "456",
                "--state-id", "state_abc",
                "--element-index", "0",
                "--scroll", "down",
                "--pages", "0.8",
            ],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.requestedAXEvent == .scroll(direction: .down, pages: 0.8))
        #expect(result.stdout.contains("scroll down 0.8 page(s)"))
        #expect(result.exitCode == 0)
    }

    @Test("post-ax-event rejects ambiguous event options")
    func postAXEventRejectsAmbiguousEventOptions() async throws {
        let fake = FakeComputerUseCore()

        let result = try await ComputerUseCLI.run(
            arguments: [
                "post-ax-event",
                "--pid", "123",
                "--window-id", "456",
                "--state-id", "state_abc",
                "--element-index", "0",
                "--focus",
                "--action", "press",
            ],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.requestedAXEvent == nil)
        #expect(result.stderr.contains("exactly one AX event option is required"))
        #expect(result.exitCode == 64)
    }

    @Test("left-click trace is opt-in and writes diagnostics to stderr")
    func leftClickTraceIsOptInAndWritesDiagnosticsToStderr() async throws {
        let fake = FakeComputerUseCore()
        await fake.setWindows([
            WindowInfo(
                id: 456,
                pid: 123,
                owner: "Google Chrome",
                title: "Trace Target",
                bounds: WindowBounds(x: 50, y: 70, width: 520, height: 360),
                zIndex: 1,
                isOnScreen: true,
                layer: 0
            )
        ])
        await fake.setLeftClickTrace(WindowMouseEventTraceResult(
            result: WindowMouseEventResult(
                pid: 123,
                windowId: 456,
                event: .click(button: .left, point: CGPoint(x: 310, y: 250))
            ),
            snapshots: [
                WindowMouseEventTraceSnapshot(
                    stage: .before,
                    frontmostPID: 999,
                    frontmostBundleIdentifier: "com.example.Front",
                    frontmostWindowId: 111,
                    targetIsActive: false,
                    targetRank: 3,
                    protectedCoveredCount: 0
                ),
                WindowMouseEventTraceSnapshot(
                    stage: .activeStateGuardTick,
                    frontmostPID: 999,
                    frontmostBundleIdentifier: "com.example.Front",
                    frontmostWindowId: 111,
                    targetIsActive: true,
                    targetRank: 1,
                    protectedCoveredCount: 1,
                    elapsedNanoseconds: 15_000_000,
                    guardAttempt: 3,
                    corrected: true
                ),
            ]
        ))

        let result = try await ComputerUseCLI.run(
            arguments: [
                "left-click",
                "--window-id", "456",
                "--coor", "260,180",
                "--trace",
            ],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.requestedLeftClickPID == nil)
        #expect(await fake.requestedLeftClickTracePID == 123)
        #expect(await fake.requestedLeftClickTraceWindowID == 456)
        #expect(await fake.requestedLeftClickTracePoint == CGPoint(x: 310, y: 250))
        #expect(await fake.stopAppSessionCallCount == 0)
        #expect(result.stdout.contains("Posted left click to window 456 at 310,250"))
        #expect(result.stderr.contains("Mouse event trace:"))
        #expect(result.stderr.contains("before: frontmost pid 999"))
        #expect(result.stderr.contains("activeStateGuardTick"))
        #expect(result.stderr.contains("elapsed-ms 15"))
        #expect(result.stderr.contains("attempt 3"))
        #expect(result.stderr.contains("corrected true"))
        #expect(result.stderr.contains("target active true"))
        #expect(result.stderr.contains("protected-covered 1"))
        #expect(result.exitCode == 0)
    }

    @Test("removed trace options are rejected")
    func removedTraceOptionsAreRejected() async throws {
        let fake = FakeComputerUseCore()
        await fake.setWindows([
            WindowInfo(
                id: 456,
                pid: 123,
                owner: "Google Chrome",
                title: "Trace Target",
                bounds: WindowBounds(x: 50, y: 70, width: 520, height: 360),
                zIndex: 1,
                isOnScreen: true,
                layer: 0
            )
        ])

        let result = try await ComputerUseCLI.run(
            arguments: [
                "left-click",
                "--window-id", "456",
                "--coor", "260,180",
                "--trace-mouse-sequence", "no-primer",
            ],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.requestedLeftClickPID == nil)
        #expect(await fake.requestedLeftClickTracePID == nil)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("unknown option --trace-mouse-sequence"))
        #expect(result.exitCode == 64)
    }

    @Test("observe-window-order samples target order without posting input")
    func observeWindowOrderSamplesTargetOrderWithoutPostingInput() async throws {
        let fake = FakeComputerUseCore()
        let observer = FakeWindowOrderObservationClient(samples: [
            WindowOrderObservationSample(
                elapsedNanoseconds: 0,
                frontmostPID: 999,
                frontmostBundleIdentifier: "com.example.Front",
                frontmostWindowId: 111,
                targetIsActive: false,
                targetRank: 2,
                protectedCoveredCount: 0,
                originalFrontmostIsActive: true
            ),
            WindowOrderObservationSample(
                elapsedNanoseconds: 5_000_000,
                frontmostPID: 999,
                frontmostBundleIdentifier: "com.example.Front",
                frontmostWindowId: 111,
                targetIsActive: true,
                targetRank: 1,
                protectedCoveredCount: 1,
                originalFrontmostIsActive: false
            ),
            WindowOrderObservationSample(
                elapsedNanoseconds: 17_000_000,
                frontmostPID: 999,
                frontmostBundleIdentifier: "com.example.Front",
                frontmostWindowId: 111,
                targetIsActive: false,
                targetRank: 2,
                protectedCoveredCount: 0,
                originalFrontmostIsActive: true
            ),
            WindowOrderObservationSample(
                elapsedNanoseconds: 20_000_000,
                frontmostPID: 999,
                frontmostBundleIdentifier: "com.example.Front",
                frontmostWindowId: 111,
                targetIsActive: false,
                targetRank: 3,
                protectedCoveredCount: 0,
                originalFrontmostIsActive: true
            ),
        ])

        let result = try await ComputerUseCLI.run(
            arguments: [
                "observe-window-order",
                "--pid", "123",
                "--window-id", "456",
                "--duration-ms", "20",
                "--interval-ms", "5",
            ],
            core: fake,
            permissions: FakePermissionClient(),
            windowOrderObserver: observer
        )

        #expect(await observer.requested == WindowOrderObservationRequest(
            pid: 123,
            windowId: 456,
            durationMilliseconds: 20,
            intervalMilliseconds: 5
        ))
        #expect(await fake.requestedLeftClickPID == nil)
        #expect(await fake.requestedLeftClickTracePID == nil)
        #expect(result.stdout.contains("Window order observation"))
        #expect(result.stdout.contains("rank-changed true"))
        #expect(result.stdout.contains("max protected-covered 1"))
        #expect(result.stdout.contains("active total 12ms, max-contiguous 12ms"))
        #expect(result.stdout.contains("rank1 total 12ms, max-contiguous 12ms"))
        #expect(result.stdout.contains("protected-covered total 12ms, max-contiguous 12ms"))
        #expect(result.stdout.contains("protected-covered 60hz frames approx 1"))
        #expect(result.stdout.contains("5ms: frontmost pid 999"))
        #expect(result.stdout.contains("original-front active false"))
        #expect(result.stderr.isEmpty)
        #expect(result.exitCode == 0)
    }

    @Test("observe-window-order JSON exposes duration metrics")
    func observeWindowOrderJSONExposesDurationMetrics() async throws {
        let observer = FakeWindowOrderObservationClient(samples: [
            WindowOrderObservationSample(
                elapsedNanoseconds: 0,
                frontmostPID: 999,
                frontmostBundleIdentifier: "com.example.Front",
                frontmostWindowId: 111,
                targetIsActive: false,
                targetRank: 2,
                protectedCoveredCount: 0,
                originalFrontmostIsActive: true
            ),
            WindowOrderObservationSample(
                elapsedNanoseconds: 5_000_000,
                frontmostPID: 999,
                frontmostBundleIdentifier: "com.example.Front",
                frontmostWindowId: 111,
                targetIsActive: true,
                targetRank: 1,
                protectedCoveredCount: 1,
                originalFrontmostIsActive: false
            ),
            WindowOrderObservationSample(
                elapsedNanoseconds: 17_000_000,
                frontmostPID: 999,
                frontmostBundleIdentifier: "com.example.Front",
                frontmostWindowId: 111,
                targetIsActive: false,
                targetRank: 2,
                protectedCoveredCount: 0,
                originalFrontmostIsActive: true
            ),
        ])

        let result = try await ComputerUseCLI.run(
            arguments: [
                "observe-window-order",
                "--pid", "123",
                "--window-id", "456",
                "--duration-ms", "20",
                "--interval-ms", "5",
                "--json",
            ],
            core: FakeComputerUseCore(),
            permissions: FakePermissionClient(),
            windowOrderObserver: observer
        )

        #expect(result.stdout.contains("\"protectedCoveredTotalMilliseconds\":12"))
        #expect(result.stdout.contains("\"protectedCoveredMaxContiguousMilliseconds\":12"))
        #expect(result.stdout.contains("\"protectedCoveredApproximate60HzFrames\":1"))
        #expect(result.stdout.contains("\"targetRankOneTotalMilliseconds\":12"))
        #expect(result.stderr.isEmpty)
        #expect(result.exitCode == 0)
    }

    @Test("measure-left-click-window-order repeats clicks and summarizes visual risk")
    func measureLeftClickWindowOrderRepeatsClicksAndSummarizesVisualRisk() async throws {
        let fake = FakeComputerUseCore()
        await fake.setWindows([
            WindowInfo(
                id: 456,
                pid: 123,
                owner: "Google Chrome",
                title: "Measured Target",
                bounds: WindowBounds(x: 50, y: 70, width: 520, height: 360),
                zIndex: 1,
                isOnScreen: true,
                layer: 0
            )
        ])
        let observer = FakeWindowOrderObservationClient(sampleBatches: [
            [
                WindowOrderObservationSample(
                    elapsedNanoseconds: 0,
                    frontmostPID: 999,
                    frontmostBundleIdentifier: "com.example.Front",
                    frontmostWindowId: 111,
                    targetIsActive: false,
                    targetRank: 2,
                    protectedCoveredCount: 0,
                    originalFrontmostIsActive: true
                ),
                WindowOrderObservationSample(
                    elapsedNanoseconds: 5_000_000,
                    frontmostPID: 999,
                    frontmostBundleIdentifier: "com.example.Front",
                    frontmostWindowId: 111,
                    targetIsActive: true,
                    targetRank: 1,
                    protectedCoveredCount: 1,
                    originalFrontmostIsActive: false
                ),
                WindowOrderObservationSample(
                    elapsedNanoseconds: 17_000_000,
                    frontmostPID: 999,
                    frontmostBundleIdentifier: "com.example.Front",
                    frontmostWindowId: 111,
                    targetIsActive: false,
                    targetRank: 2,
                    protectedCoveredCount: 0,
                    originalFrontmostIsActive: true
                ),
            ],
            [
                WindowOrderObservationSample(
                    elapsedNanoseconds: 0,
                    frontmostPID: 999,
                    frontmostBundleIdentifier: "com.example.Front",
                    frontmostWindowId: 111,
                    targetIsActive: false,
                    targetRank: 2,
                    protectedCoveredCount: 0,
                    originalFrontmostIsActive: true
                ),
                WindowOrderObservationSample(
                    elapsedNanoseconds: 20_000_000,
                    frontmostPID: 999,
                    frontmostBundleIdentifier: "com.example.Front",
                    frontmostWindowId: 111,
                    targetIsActive: false,
                    targetRank: 2,
                    protectedCoveredCount: 0,
                    originalFrontmostIsActive: true
                ),
            ],
        ])

        let result = try await ComputerUseCLI.run(
            arguments: [
                "measure-left-click-window-order",
                "--window-id", "456",
                "--coor", "10,20",
                "--runs", "2",
                "--duration-ms", "20",
                "--interval-ms", "5",
                "--pre-click-delay-ms", "0",
                "--between-runs-ms", "0",
            ],
            core: fake,
            permissions: FakePermissionClient(),
            windowOrderObserver: observer
        )

        #expect(await fake.requestedLeftClickCount == 2)
        #expect(await fake.requestedWindowPID == 123)
        #expect(await fake.requestedLeftClickPoint == CGPoint(x: 60, y: 90))
        #expect(await observer.requests == [
            WindowOrderObservationRequest(
                pid: 123,
                windowId: 456,
                durationMilliseconds: 20,
                intervalMilliseconds: 5
            ),
            WindowOrderObservationRequest(
                pid: 123,
                windowId: 456,
                durationMilliseconds: 20,
                intervalMilliseconds: 5
            ),
        ])
        #expect(result.stdout.contains("Left click window order measurement"))
        #expect(result.stdout.contains("Runs: 2, protected-covered-observed 1/2"))
        #expect(result.stdout.contains("max protected-covered contiguous 12ms"))
        #expect(result.stdout.contains("Run 1: active 12ms, rank1 12ms, protected-covered 12ms, frames 1"))
        #expect(result.stdout.contains("Run 2: active 0ms, rank1 0ms, protected-covered 0ms, frames 0"))
        #expect(result.stderr.isEmpty)
        #expect(result.exitCode == 0)
    }

    @Test("observe-window-order rejects zero interval")
    func observeWindowOrderRejectsZeroInterval() async throws {
        let result = try await ComputerUseCLI.run(
            arguments: [
                "observe-window-order",
                "--pid", "123",
                "--window-id", "456",
                "--interval-ms", "0",
            ],
            core: FakeComputerUseCore(),
            permissions: FakePermissionClient(),
            windowOrderObserver: FakeWindowOrderObservationClient(samples: [])
        )

        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("invalid value for --interval-ms: 0"))
        #expect(result.exitCode == 64)
    }

    @Test("observe-mouse-events records mouse event fields for Codex comparison")
    func observeMouseEventsRecordsMouseEventFields() async throws {
        let observer = FakeMouseEventObservationClient(samples: [
            MouseEventObservationSample(
                tapLocation: .hid,
                elapsedNanoseconds: 2_000_000,
                typeRawValue: UInt32(CGEventType.leftMouseDown.rawValue),
                typeName: "leftMouseDown",
                location: CGPoint(x: 90, y: 343),
                sourcePID: 777,
                targetPID: 123,
                buttonNumber: 0,
                clickState: 1,
                subtype: 3,
                windowUnderMousePointer: 456,
                windowUnderMousePointerThatCanHandleThisEvent: 456,
                rawField0: 3,
                rawField40: 123,
                rawField51: 456,
                rawField58: 99,
                rawField91: 456,
                rawField92: 456,
                matchesRequestedTarget: true
            ),
        ])

        let result = try await ComputerUseCLI.run(
            arguments: [
                "observe-mouse-events",
                "--pid", "123",
                "--window-id", "456",
                "--duration-ms", "20",
                "--tap-location", "all",
            ],
            core: FakeComputerUseCore(),
            permissions: FakePermissionClient(),
            mouseEventObserver: observer
        )

        #expect(await observer.requested == MouseEventObservationRequest(
            pid: 123,
            windowId: 456,
            durationMilliseconds: 20,
            tapLocation: .all
        ))
        #expect(result.stdout.contains("Mouse event observation"))
        #expect(result.stdout.contains("Target: pid 123, window 456"))
        #expect(result.stdout.contains("Taps: all"))
        #expect(result.stdout.contains("2ms: hid leftMouseDown loc 90,343"))
        #expect(result.stdout.contains("source-pid 777 target-pid 123"))
        #expect(result.stdout.contains("window-under 456 can-handle 456"))
        #expect(result.stdout.contains("raw[0]=3 raw[40]=123 raw[51]=456 raw[58]=99 raw[91]=456 raw[92]=456"))
        #expect(result.stderr.isEmpty)
        #expect(result.exitCode == 0)
    }

    @Test("post-cursor accepts explicit target and posts click at adjusted local coordinate")
    func postCursorAcceptsExplicitTargetAndPostsAdjustedCoordinate() async throws {
        let fake = FakeComputerUseCore()
        let io = FakePostCursorIO(lines: ["left-click"], keys: [.right, .down, .confirm, .quit])
        let overlay = FakePostCursorOverlay()
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
            arguments: ["post-cursor", "--window-id", "456", "--coor", "260,180"],
            core: fake,
            permissions: FakePermissionClient(),
            postCursorIO: io,
            postCursorOverlay: overlay
        )

        #expect(await fake.requestedWindowPID == 123)
        #expect(await fake.requestedLeftClickPID == 123)
        #expect(await fake.requestedLeftClickWindowID == 456)
        #expect(await fake.requestedLeftClickPoint == CGPoint(x: 320, y: 260))
        #expect(await fake.requestedMouseEvents == [
            .click(button: .left, point: CGPoint(x: 320, y: 260)),
        ])
        #expect(await overlay.points == [
            CGPoint(x: 310, y: 250),
            CGPoint(x: 320, y: 250),
            CGPoint(x: 320, y: 260),
        ])
        #expect(await overlay.hidden == true)
        #expect(await !io.writes.contains { $0.contains("cursor local") })
        #expect(result.stdout.contains("Post cursor exited after 1 left-click event(s) at local 270,190 / screen 320,260"))
        #expect(result.stderr.isEmpty)
        #expect(result.exitCode == 0)
    }

    @Test("post-cursor repeats the selected event from the last cursor position")
    func postCursorRepeatsSelectedEventFromLastPosition() async throws {
        let fake = FakeComputerUseCore()
        let io = FakePostCursorIO(lines: ["right-click"], keys: [.confirm, .right, .confirm, .quit])
        let overlay = FakePostCursorOverlay()
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
            arguments: ["post-cursor", "--window-id", "456", "--coor", "260,180"],
            core: fake,
            permissions: FakePermissionClient(),
            postCursorIO: io,
            postCursorOverlay: overlay
        )

        #expect(await fake.requestedMouseEvents == [
            .click(button: .right, point: CGPoint(x: 310, y: 250)),
            .click(button: .right, point: CGPoint(x: 320, y: 250)),
        ])
        #expect(await overlay.points == [
            CGPoint(x: 310, y: 250),
            CGPoint(x: 320, y: 250),
        ])
        #expect(result.stdout.contains("Post cursor exited after 2 right-click event(s) at local 270,180 / screen 320,250"))
        #expect(result.exitCode == 0)
    }

    @Test("post-cursor uses cursor-confirmed drag endpoints")
    func postCursorUsesCursorConfirmedDragEndpoints() async throws {
        let fake = FakeComputerUseCore()
        let io = FakePostCursorIO(lines: ["drag"], keys: [.confirm, .right, .down, .confirm, .quit])
        let overlay = FakePostCursorOverlay()
        await fake.setAppType(AppTypeResult(
            pid: 123,
            appName: "Chrome",
            bundleId: "com.google.Chrome",
            bundlePath: "/Applications/Google Chrome.app",
            type: .webContent,
            reason: .chromiumBrowserBundleId
        ))
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
            arguments: ["post-cursor", "--window-id", "456", "--coor", "260,180"],
            core: fake,
            permissions: FakePermissionClient(),
            postCursorIO: io,
            postCursorOverlay: overlay
        )

        #expect(await fake.requestedMouseEvents == [
            .drag(
                button: .left,
                from: CGPoint(x: 310, y: 250),
                to: CGPoint(x: 320, y: 260)
            ),
        ])
        #expect(await overlay.points == [
            CGPoint(x: 310, y: 250),
            CGPoint(x: 320, y: 250),
            CGPoint(x: 320, y: 260),
        ])
        #expect(result.stdout.contains("Post cursor exited after 1 drag event(s) at local 270,190 / screen 320,260"))
        #expect(result.exitCode == 0)
    }

    @Test("post-cursor rejects drag for AppKit targets")
    func postCursorRejectsDragForAppKitTargets() async throws {
        let fake = FakeComputerUseCore()
        let io = FakePostCursorIO(lines: ["drag"], keys: [])
        let overlay = FakePostCursorOverlay()
        await fake.setAppType(AppTypeResult(
            pid: 123,
            appName: "Finder",
            bundleId: "com.apple.finder",
            bundlePath: "/System/Library/CoreServices/Finder.app",
            type: .appKit,
            reason: .appKitDefault
        ))
        await fake.setWindows([
            WindowInfo(
                id: 456,
                pid: 123,
                owner: "Finder",
                title: "Finder",
                bounds: WindowBounds(x: 50, y: 70, width: 520, height: 360),
                zIndex: 1,
                isOnScreen: true,
                layer: 0
            )
        ])

        let result = try await ComputerUseCLI.run(
            arguments: ["post-cursor", "--window-id", "456", "--coor", "260,180"],
            core: fake,
            permissions: FakePermissionClient(),
            postCursorIO: io,
            postCursorOverlay: overlay
        )

        #expect(await fake.requestedAppTypePID == 123)
        #expect(await fake.requestedMouseEvents.isEmpty)
        #expect(await overlay.points.isEmpty)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("drag is only supported for web-content targets"))
        #expect(result.stderr.contains("Finder"))
        #expect(result.exitCode == 64)
    }

    @Test("post-cursor prompts for current-session window when omitted")
    func postCursorPromptsForTargetWhenOmitted() async throws {
        let fake = FakeComputerUseCore()
        let io = FakePostCursorIO(lines: ["456", "left-click"], keys: [.quit])
        let overlay = FakePostCursorOverlay()
        await fake.setWindows([
            WindowInfo(
                id: 456,
                pid: 123,
                owner: "Target",
                title: "Main",
                bounds: WindowBounds(x: 10, y: 20, width: 100, height: 80),
                zIndex: 1,
                isOnScreen: true,
                layer: 0
            )
        ])

        let result = try await ComputerUseCLI.run(
            arguments: ["post-cursor"],
            core: fake,
            permissions: FakePermissionClient(),
            postCursorIO: io,
            postCursorOverlay: overlay
        )

        #expect(await fake.requestedWindowPID == 123)
        #expect(await fake.requestedLeftClickPID == nil)
        #expect(await io.prompts == [
            "Select window id: ",
            "Select mouse event (left-click/right-click/drag): ",
        ])
        #expect(await overlay.points == [CGPoint(x: 60, y: 60)])
        #expect(result.stdout.contains("Post cursor exited without posting left-click at local 50,40 / screen 60,60"))
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

    @Test("post-left-click command is not accepted")
    func postLeftClickCommandIsNotAccepted() async throws {
        let fake = FakeComputerUseCore()

        let result = try await ComputerUseCLI.run(
            arguments: ["post-left-click", "--pid", "123", "--window-id", "456", "--coor", "10,20"],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.requestedMouseEvent == nil)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("unknown command post-left-click"))
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

    @Test("trace-postLeftClick command is not accepted")
    func tracePostLeftClickCommandIsNotAccepted() async throws {
        let fake = FakeComputerUseCore()

        let result = try await ComputerUseCLI.run(
            arguments: ["trace-postLeftClick", "--pid", "123", "--window-id", "456", "--skip-focus"],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(await fake.requestedLeftClickPID == nil)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("unknown command trace-postLeftClick"))
        #expect(result.exitCode == 64)
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

    @Test("get-app-type supports machine-readable JSON output")
    func getAppTypeSupportsMachineReadableJSONOutput() async throws {
        let fake = FakeComputerUseCore()
        await fake.setAppType(AppTypeResult(
            pid: 123,
            appName: "Postman",
            bundleId: "com.postmanlabs.mac",
            bundlePath: "/Applications/Postman.app",
            type: .webContent,
            reason: .electronFramework
        ))

        let result = try await ComputerUseCLI.run(
            arguments: ["get-app-type", "--pid", "123", "--json"],
            core: fake,
            permissions: FakePermissionClient()
        )

        #expect(result.stdout.contains("\"command\":\"get-app-type\""))
        #expect(result.stdout.contains("\"type\":\"webContent\""))
        #expect(result.stdout.contains("\"reason\":\"electronFramework\""))
        #expect(result.stdout.contains("\"bundleId\":\"com.postmanlabs.mac\""))
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

private actor FakePostCursorIO: PostCursorIO {
    private var lines: [String]
    private var keys: [PostCursorKey]
    private(set) var writes: [String] = []
    private(set) var prompts: [String] = []

    init(lines: [String] = [], keys: [PostCursorKey]) {
        self.lines = lines
        self.keys = keys
    }

    func write(_ text: String) async {
        writes.append(text)
    }

    func readLine(prompt: String) async throws -> String {
        prompts.append(prompt)
        return lines.removeFirst()
    }

    func readKey() async throws -> PostCursorKey {
        keys.removeFirst()
    }
}

private actor FakePostCursorOverlay: PostCursorOverlay {
    private(set) var points: [CGPoint] = []
    private(set) var hidden = false

    func show(at point: CGPoint) async throws {
        points.append(point)
    }

    func move(to point: CGPoint) async throws {
        points.append(point)
    }

    func hide() async {
        hidden = true
    }
}

private actor FakeInteractiveCLIIO: InteractiveCLIIO {
    private var lines: [String]
    private var keys: [TerminalKey]
    private let throwsWhenKeysAreExhausted: Bool
    private(set) var status: [String] = []
    private(set) var output: [String] = []
    private(set) var error: [String] = []
    private(set) var prompts: [String] = []

    init(lines: [String] = [], keys: [TerminalKey], throwsWhenKeysAreExhausted: Bool = false) {
        self.lines = lines
        self.keys = keys
        self.throwsWhenKeysAreExhausted = throwsWhenKeysAreExhausted
    }

    func write(_ text: String) async {
        status.append(text)
    }

    func writeOutput(_ text: String) async {
        output.append(text)
    }

    func writeError(_ text: String) async {
        error.append(text)
    }

    func readLine(prompt: String) async throws -> String {
        prompts.append(prompt)
        return lines.removeFirst()
    }

    func readKey() async throws -> TerminalKey {
        if throwsWhenKeysAreExhausted, keys.isEmpty {
            throw FakeInteractiveCLIIOError.exhaustedKeys
        }
        return keys.removeFirst()
    }
}

private enum FakeInteractiveCLIIOError: Error, CustomStringConvertible {
    case exhaustedKeys

    var description: String {
        switch self {
        case .exhaustedKeys:
            "fake interactive key queue exhausted"
        }
    }
}

private actor FakeWindowOrderObservationClient: WindowOrderObservationClient {
    private var sampleBatches: [[WindowOrderObservationSample]]
    private(set) var requested: WindowOrderObservationRequest?
    private(set) var requests: [WindowOrderObservationRequest] = []

    init(samples: [WindowOrderObservationSample]) {
        self.sampleBatches = [samples]
    }

    init(sampleBatches: [[WindowOrderObservationSample]]) {
        self.sampleBatches = sampleBatches
    }

    func observe(_ request: WindowOrderObservationRequest) async throws -> [WindowOrderObservationSample] {
        self.requested = request
        self.requests.append(request)
        guard !sampleBatches.isEmpty else {
            Issue.record("FakeWindowOrderObservationClient exhausted sample batches")
            return []
        }
        return sampleBatches.removeFirst()
    }
}

private actor FakeMouseEventObservationClient: MouseEventObservationClient {
    private let samples: [MouseEventObservationSample]
    private(set) var requested: MouseEventObservationRequest?

    init(samples: [MouseEventObservationSample]) {
        self.samples = samples
    }

    func observe(_ request: MouseEventObservationRequest) async throws -> [MouseEventObservationSample] {
        self.requested = request
        return samples
    }
}

private actor FakeComputerUseCore: ComputerUseCoreClient, ComputerUseDiagnosticsClient {
    var apps: [AppInfo] = []
    var windows: [WindowInfo] = []
    var state: AppStateBundle?
    var appType: AppTypeResult?

    private(set) var requestedAppMode: AppListMode?
    private(set) var requestedWindowPID: pid_t?
    private(set) var requestedAppTypePID: pid_t?
    private(set) var requestedStatePID: pid_t?
    private(set) var requestedStateWindowID: CGWindowID?
    private(set) var requestedCaptureMode: CaptureMode?
    private(set) var requestedMaxImageDimension: Int?
    private(set) var requestedFocusPID: pid_t?
    private(set) var requestedFocusWindowID: CGWindowID?
    private(set) var requestedStartAppSessionPID: pid_t?
    private(set) var requestedStartAppSessionWindowID: CGWindowID?
    private(set) var stopAppSessionCallCount = 0
    private(set) var requestedLeftClickPID: pid_t?
    private(set) var requestedLeftClickWindowID: CGWindowID?
    private(set) var requestedLeftClickPoint: CGPoint?
    private(set) var requestedLeftClickCount = 0
    private(set) var requestedLeftClickTracePID: pid_t?
    private(set) var requestedLeftClickTraceWindowID: CGWindowID?
    private(set) var requestedLeftClickTracePoint: CGPoint?
    private(set) var requestedMouseEvent: BackgroundMouseEvent?
    private(set) var requestedMouseEvents: [BackgroundMouseEvent] = []
    private(set) var requestedMouseEventTrace: BackgroundMouseEvent?
    private(set) var requestedKeyboardEvent: BackgroundKeyboardEvent?
    private(set) var requestedAXEventPID: pid_t?
    private(set) var requestedAXEventWindowID: CGWindowID?
    private(set) var requestedAXEventStateID: StateID?
    private(set) var requestedAXEventElementIndex: Int?
    private(set) var requestedAXEvent: AXElementEvent?
    private var leftClickTrace: WindowMouseEventTraceResult?
    private var activeAppSession: AppSessionResult? = AppSessionResult(pid: 123)
    private var stoppedAppSession = AppSessionResult(pid: 0)

    nonisolated var diagnosticsClient: ComputerUseDiagnosticsClient {
        self
    }

    func setApps(_ apps: [AppInfo]) {
        self.apps = apps
    }

    func setWindows(_ windows: [WindowInfo]) {
        self.windows = windows
    }

    func setState(_ state: AppStateBundle) {
        self.state = state
    }

    func setAppType(_ appType: AppTypeResult) {
        self.appType = appType
    }

    func setLeftClickTrace(_ trace: WindowMouseEventTraceResult) {
        self.leftClickTrace = trace
    }

    func setStoppedAppSession(_ result: AppSessionResult) {
        self.stoppedAppSession = result
    }

    func setActiveAppSession(_ result: AppSessionResult) {
        self.activeAppSession = result
    }

    func listApps(mode: AppListMode) async throws -> [AppInfo] {
        requestedAppMode = mode
        return apps
    }

    func listWindows(pid: pid_t) async throws -> [WindowInfo] {
        requestedWindowPID = pid
        return windows
    }

    func getAppType(pid: pid_t) async throws -> AppTypeResult {
        requestedAppTypePID = pid
        return try #require(appType)
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

    func startAppSession(pid: pid_t, windowId: CGWindowID) async throws -> AppSessionResult {
        requestedStartAppSessionPID = pid
        requestedStartAppSessionWindowID = windowId
        let result = AppSessionResult(pid: pid)
        activeAppSession = result
        return result
    }

    func stopAppSession() async throws -> AppSessionResult {
        guard activeAppSession != nil else {
            throw ComputerUseError.appSessionUnavailable("no active app session")
        }
        stopAppSessionCallCount += 1
        activeAppSession = nil
        return stoppedAppSession
    }

    func currentAppSession() async throws -> AppSessionResult {
        guard let activeAppSession else {
            throw ComputerUseError.appSessionUnavailable("no active app session")
        }
        return activeAppSession
    }

    func postMouseEvent(
        windowId: CGWindowID,
        event: BackgroundMouseEvent
    ) async throws -> WindowMouseEventResult {
        let pid = try await currentAppSession().pid
        requestedMouseEvent = event
        requestedMouseEvents.append(event)
        if case .click(.left, let point, _) = event {
            requestedLeftClickPID = pid
            requestedLeftClickWindowID = windowId
            requestedLeftClickPoint = point
            requestedLeftClickCount += 1
        }
        return WindowMouseEventResult(pid: pid, windowId: windowId, event: event)
    }

    func postMouseEventTrace(
        windowId: CGWindowID,
        event: BackgroundMouseEvent
    ) async throws -> WindowMouseEventTraceResult {
        let pid = try await currentAppSession().pid
        requestedMouseEventTrace = event
        if case .click(.left, let point, _) = event {
            requestedLeftClickTracePID = pid
            requestedLeftClickTraceWindowID = windowId
            requestedLeftClickTracePoint = point
        }
        if let leftClickTrace {
            return leftClickTrace
        }
        return WindowMouseEventTraceResult(
            result: WindowMouseEventResult(pid: pid, windowId: windowId, event: event),
            snapshots: []
        )
    }

    func observeWindowOrder(
        pid: pid_t,
        windowId: CGWindowID,
        durationMilliseconds: Int,
        intervalMilliseconds: Int
    ) async throws -> [WindowOrderObservationSample] {
        []
    }

    func postKeyboardEvent(
        windowId: CGWindowID,
        event: BackgroundKeyboardEvent
    ) async throws -> WindowKeyboardEventResult {
        let pid = try await currentAppSession().pid
        requestedKeyboardEvent = event
        return WindowKeyboardEventResult(pid: pid, windowId: windowId, event: event)
    }

    func postEventToAXElement(
        pid: pid_t,
        windowId: CGWindowID,
        stateId: StateID,
        elementIndex: Int,
        event: AXElementEvent
    ) async throws -> AXElementEventResult {
        requestedAXEventPID = pid
        requestedAXEventWindowID = windowId
        requestedAXEventStateID = stateId
        requestedAXEventElementIndex = elementIndex
        requestedAXEvent = event
        return AXElementEventResult(
            pid: pid,
            windowId: windowId,
            stateId: stateId,
            elementIndex: elementIndex,
            event: event
        )
    }

}

private struct FakeComputerUseCoreError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }

    init(_ message: String) {
        self.message = message
    }
}
