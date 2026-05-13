import AOSComputerUseKit
import CoreGraphics
import Darwin
import Foundation

struct InteractiveCLICommandItem: Sendable {
    let title: String
    let buildArguments: @Sendable (InteractiveCLICommandContext) async throws -> [String]
}

struct InteractiveCLICommandContext: Sendable {
    let core: ComputerUseCoreClient
    let io: InteractiveCLIIO
}

enum InteractiveCLICommandCatalog {
    static let items: [InteractiveCLICommandItem] = [
        command("start-app-session") { context in
            let target = try await promptTarget(context)
            return ["start-app-session", "--pid", "\(target.pid)", "--window-id", "\(target.windowId)"]
        },
        command("stop-app-session") { _ in
            ["stop-app-session"]
        },
        command("list-apps") { context in
            let mode = try await select("App list mode", options: AppListMode.allCases, context: context)
            return ["list-apps", "--mode", mode.rawValue]
        },
        command("list-windows") { context in
            let pid = try await promptPID(context)
            return ["list-windows", "--pid", "\(pid)"]
        },
        command("get-app-type") { context in
            let pid = try await promptPID(context)
            return ["get-app-type", "--pid", "\(pid)"]
        },
        command("get-app-state") { context in
            let target = try await promptTarget(context)
            let mode = try await select("Capture mode", options: CaptureMode.allCases, context: context)
            var arguments = [
                "get-app-state",
                "--pid", "\(target.pid)",
                "--window-id", "\(target.windowId)",
                "--mode", mode.rawValue,
            ]
            if let maxImageDimension = try await context.io.promptOptional("Max image dimension (empty for 0): ") {
                arguments += ["--max-image-dimension", maxImageDimension]
            }
            if let screenshotOutput = try await context.io.promptOptional("Screenshot output path (empty to skip): ") {
                arguments += ["--screenshot-output", screenshotOutput]
            }
            return arguments
        },
        command("focus-window") { context in
            let target = try await promptTarget(context)
            return ["focus-window", "--pid", "\(target.pid)", "--window-id", "\(target.windowId)"]
        },
        command("left-click") { context in
            let target = try await promptCurrentSessionWindow(context)
            var arguments = [
                "left-click",
                "--window-id", "\(target.windowId)",
                "--coor", try await context.io.promptRequired("Coordinate x,y: "),
            ]
            if let count = try await context.io.promptOptional("Count (empty for 1): ") {
                arguments += ["--count", count]
            }
            if try await select("Trace mouse event?", options: Bool.interactiveOptions, context: context) {
                arguments.append("--trace")
            }
            return arguments
        },
        command("right-click") { context in
            let target = try await promptCurrentSessionWindow(context)
            var arguments = [
                "right-click",
                "--window-id", "\(target.windowId)",
                "--coor", try await context.io.promptRequired("Coordinate x,y: "),
            ]
            if let count = try await context.io.promptOptional("Count (empty for 1): ") {
                arguments += ["--count", count]
            }
            if try await select("Trace mouse event?", options: Bool.interactiveOptions, context: context) {
                arguments.append("--trace")
            }
            return arguments
        },
        command("drag") { context in
            let target = try await promptCurrentSessionWindow(context)
            let button = try await select("Mouse button", options: BackgroundMouseButton.allCases, context: context)
            var arguments = [
                "drag",
                "--window-id", "\(target.windowId)",
                "--from", try await context.io.promptRequired("Start coordinate x,y: "),
                "--to", try await context.io.promptRequired("End coordinate x,y: "),
                "--button", button.rawValue,
            ]
            if try await select("Trace mouse event?", options: Bool.interactiveOptions, context: context) {
                arguments.append("--trace")
            }
            return arguments
        },
        command("type-text") { context in
            let target = try await promptCurrentSessionWindow(context)
            var arguments = [
                "type-text",
                "--window-id", "\(target.windowId)",
                "--text", try await context.io.promptRequired("Text: "),
            ]
            if let delay = try await context.io.promptOptional("Delay ms (empty for 30): ") {
                arguments += ["--delay-ms", delay]
            }
            return arguments
        },
        command("press-key") { context in
            let target = try await promptCurrentSessionWindow(context)
            var arguments = [
                "press-key",
                "--window-id", "\(target.windowId)",
                "--key", try await context.io.promptRequired("Key: "),
            ]
            if let modifiers = try await context.io.promptOptional("Modifiers csv (empty for none): ") {
                arguments += ["--modifiers", modifiers]
            }
            if let count = try await context.io.promptOptional("Count (empty for 1): ") {
                arguments += ["--count", count]
            }
            return arguments
        },
        command("hotkey") { context in
            let target = try await promptCurrentSessionWindow(context)
            return [
                "hotkey",
                "--window-id", "\(target.windowId)",
                "--keys", try await context.io.promptRequired("Keys csv, e.g. cmd,shift,s: "),
            ]
        },
        command("measure-left-click-window-order") { context in
            let target = try await promptCurrentSessionWindow(context)
            var arguments = [
                "measure-left-click-window-order",
                "--window-id", "\(target.windowId)",
                "--coor", try await context.io.promptRequired("Coordinate x,y: "),
            ]
            try await appendOptionalIntPrompts(
                to: &arguments,
                context: context,
                prompts: [
                    ("--runs", "Runs (empty for 10): "),
                    ("--duration-ms", "Duration ms (empty for 8000): "),
                    ("--interval-ms", "Interval ms (empty for 1): "),
                    ("--pre-click-delay-ms", "Pre-click delay ms (empty for 2000): "),
                    ("--between-runs-ms", "Between-runs ms (empty for 300): "),
                ]
            )
            return arguments
        },
        command("observe-window-order") { context in
            let target = try await promptTarget(context)
            var arguments = [
                "observe-window-order",
                "--pid", "\(target.pid)",
                "--window-id", "\(target.windowId)",
            ]
            try await appendOptionalIntPrompts(
                to: &arguments,
                context: context,
                prompts: [
                    ("--duration-ms", "Duration ms (empty for 5000): "),
                    ("--interval-ms", "Interval ms (empty for 5): "),
                ]
            )
            return arguments
        },
        command("observe-mouse-events") { context in
            var arguments = ["observe-mouse-events"]
            if try await select("Filter to a target?", options: Bool.interactiveOptions, context: context) {
                let target = try await promptTarget(context)
                arguments += ["--pid", "\(target.pid)", "--window-id", "\(target.windowId)"]
            }
            if let duration = try await context.io.promptOptional("Duration ms (empty for 5000): ") {
                arguments += ["--duration-ms", duration]
            }
            let tapLocation = try await select("Tap location", options: MouseEventTapLocation.allCases, context: context)
            arguments += ["--tap-location", tapLocation.rawValue]
            return arguments
        },
        command("post-cursor") { context in
            let target = try await promptCurrentSessionWindow(context)
            var arguments = [
                "post-cursor",
                "--window-id", "\(target.windowId)",
            ]
            if let coordinate = try await context.io.promptOptional("Initial coordinate x,y (empty for center): ") {
                arguments += ["--coor", coordinate]
            }
            return arguments
        },
        command("open-coor-test") { _ in
            ["open-coor-test"]
        },
        command("grant-permissions") { _ in
            ["grant-permissions"]
        },
        command("post-ax-event") { context in
            let target = try await promptTarget(context)
            var arguments = [
                "post-ax-event",
                "--pid", "\(target.pid)",
                "--window-id", "\(target.windowId)",
                "--state-id", try await context.io.promptRequired("State ID: "),
                "--element-index", try await context.io.promptRequired("Element index: "),
            ]
            let eventKind = try await select("AX event", options: AXElementEventKind.allCases, context: context)
            switch eventKind {
            case .focus:
                arguments.append("--focus")
            case .action:
                let action = try await select("AX action", options: AXElementAction.allCases, context: context)
                arguments += ["--action", action.rawValue]
            case .setValue:
                arguments += ["--set-value", try await context.io.promptRequired("Value: ")]
            case .setSelectedText:
                arguments += ["--set-selected-text", try await context.io.promptRequired("Selected text: ")]
            case .scroll:
                let direction = try await select("Scroll direction", options: AXScrollDirection.allCases, context: context)
                arguments += ["--scroll", direction.rawValue]
                if let pages = try await context.io.promptOptional("Pages (empty for 1): ") {
                    arguments += ["--pages", pages]
                }
            }
            return arguments
        },
    ]

    private static func command(
        _ title: String,
        buildArguments: @escaping @Sendable (InteractiveCLICommandContext) async throws -> [String]
    ) -> InteractiveCLICommandItem {
        InteractiveCLICommandItem(title: title, buildArguments: buildArguments)
    }

    private static func promptTarget(_ context: InteractiveCLICommandContext) async throws -> AppSessionTargetRequest {
        let pid = try await promptPID(context)
        let windows = try await context.core.listWindows(pid: pid)
        if windows.isEmpty {
            let windowId = try await parseWindowID(context.io.promptRequired("Window ID: "))
            return AppSessionTargetRequest(pid: pid, windowId: windowId)
        }
        let window = try await InteractiveSelectionMenu(
            title: "Window",
            options: windows.map {
                InteractiveSelectionOption(
                    title: "\($0.id) \($0.title.isEmpty ? "(untitled)" : $0.title) \($0.bounds.width)x\($0.bounds.height)",
                    value: $0
                )
            }
        ).select(using: context.io)
        return AppSessionTargetRequest(pid: pid, windowId: window.id)
    }

    private static func promptPID(_ context: InteractiveCLICommandContext) async throws -> pid_t {
        let apps = try await context.core.listApps(mode: .running).filter { $0.pid != nil }
        if apps.isEmpty {
            return try await parsePID(context.io.promptRequired("PID: "))
        }
        return try await InteractiveSelectionMenu(
            title: "App",
            options: apps.map {
                InteractiveSelectionOption(
                    title: "\($0.name) pid \($0.pid!)\($0.active ? " active" : "")",
                    value: $0.pid!
                )
            } + [
                InteractiveSelectionOption(title: "Enter PID manually", value: pid_t(0)),
            ]
        ).select(using: context.io).nonZeroOrPrompt(context.io)
    }

    private static func promptCurrentSessionWindow(_ context: InteractiveCLICommandContext) async throws -> AppSessionTargetRequest {
        let session = try await context.core.currentAppSession()
        let windows = try await context.core.listWindows(pid: session.pid)
        guard !windows.isEmpty else {
            throw UsageError("no windows available for active app session pid \(session.pid)")
        }
        let window = try await InteractiveSelectionMenu(
            title: "Window",
            options: windows.map {
                InteractiveSelectionOption(
                    title: "\($0.id) \($0.title.isEmpty ? "(untitled)" : $0.title) \($0.bounds.width)x\($0.bounds.height)",
                    value: $0
                )
            }
        ).select(using: context.io)
        return AppSessionTargetRequest(pid: session.pid, windowId: window.id)
    }

    private static func parsePID(_ raw: String) throws -> pid_t {
        guard let parsed = Int32(raw), parsed > 0 else {
            throw UsageError("invalid pid: \(raw)")
        }
        return pid_t(parsed)
    }

    private static func parseWindowID(_ raw: String) throws -> CGWindowID {
        guard let parsed = UInt32(raw) else {
            throw UsageError("invalid window id: \(raw)")
        }
        return CGWindowID(parsed)
    }

    private static func select<T: InteractiveMenuValue>(
        _ title: String,
        options: [T],
        context: InteractiveCLICommandContext
    ) async throws -> T {
        try await InteractiveSelectionMenu(
            title: title,
            options: options.map { InteractiveSelectionOption(title: $0.interactiveTitle, value: $0) }
        ).select(using: context.io)
    }

    private static func appendOptionalIntPrompts(
        to arguments: inout [String],
        context: InteractiveCLICommandContext,
        prompts: [(String, String)]
    ) async throws {
        for (option, prompt) in prompts {
            if let value = try await context.io.promptOptional(prompt) {
                arguments += [option, value]
            }
        }
    }
}

extension ComputerUseCLI {
    static func runInteractiveSession(
        core: ComputerUseCoreClient,
        permissions: ComputerUsePermissionClient,
        coorTestTarget: CoorTestTargetClient,
        postCursorIO: PostCursorIO,
        postCursorOverlay: PostCursorOverlay,
        interactiveIO: InteractiveCLIIO,
        windowOrderObserver: WindowOrderObservationClient,
        mouseEventObserver: MouseEventObservationClient
    ) async throws {
        var outputRegion = TerminalRenderRegion()
        let menu = InteractiveSelectionMenu(
            title: "Command",
            options: InteractiveCLICommandCatalog.items.map {
                InteractiveSelectionOption(title: $0.title, value: $0)
            },
            allowsPrefixMatching: true
        )
        do {
            await interactiveIO.write("AOS Computer Use interactive CLI. Use Up/Down, Enter to execute, Q to exit.\n")
            commandLoop: while true {
                let item: InteractiveCLICommandItem
                do {
                    item = try await menu.select(using: interactiveIO)
                } catch InteractiveCLISessionControl.cancelled {
                    await interactiveIO.write("Interactive CLI exited.\n")
                    break commandLoop
                }

                do {
                    let arguments = try await item.buildArguments(InteractiveCLICommandContext(core: core, io: interactiveIO))
                    let result = try await run(
                        arguments: arguments,
                        core: core,
                        permissions: permissions,
                        coorTestTarget: coorTestTarget,
                        postCursorIO: postCursorIO,
                        postCursorOverlay: postCursorOverlay,
                        interactiveIO: interactiveIO,
                        windowOrderObserver: windowOrderObserver,
                        mouseEventObserver: mouseEventObserver
                    )
                    let sections = [
                        InteractiveOutputSection.render(title: "Output", text: result.stdout),
                        InteractiveOutputSection.render(title: "Error", text: result.stderr),
                    ].filter { !$0.isEmpty }
                    if !sections.isEmpty {
                        await outputRegion.replace(with: sections.joined(separator: "\n\n"), io: interactiveIO)
                    }
                } catch InteractiveCLISessionControl.cancelled {
                    await interactiveIO.write("Cancelled.\n")
                } catch let error as CancellationError {
                    throw error
                } catch {
                    await outputRegion.replace(
                        with: InteractiveOutputSection.render(title: "Error", text: String(describing: error)),
                        io: interactiveIO
                    )
                }
            }
        } catch {
            try await stopActiveAppSessionIfAvailable(core: core)
            throw error
        }
        try await stopActiveAppSessionIfAvailable(core: core)
    }

    static func stopActiveAppSessionIfAvailable(core: ComputerUseCoreClient) async throws {
        do {
            _ = try await core.currentAppSession()
        } catch let error where isAppSessionUnavailable(error) {
            return
        }

        do {
            _ = try await core.stopAppSession()
        } catch let error where isAppSessionUnavailable(error) {
            return
        }
    }

    private static func isAppSessionUnavailable(_ error: Error) -> Bool {
        guard case ComputerUseError.appSessionUnavailable = error else {
            return false
        }
        return true
    }
}

protocol InteractiveMenuValue: Sendable {
    var interactiveTitle: String { get }
}

extension AppListMode: CaseIterable, InteractiveMenuValue {
    public static var allCases: [AppListMode] { [.running, .all] }
    var interactiveTitle: String { rawValue }
}

extension CaptureMode: CaseIterable, InteractiveMenuValue {
    public static var allCases: [CaptureMode] { [.vision, .ax] }
    var interactiveTitle: String { rawValue }
}

extension BackgroundMouseButton: CaseIterable, InteractiveMenuValue {
    public static var allCases: [BackgroundMouseButton] { [.left, .right] }
    var interactiveTitle: String { rawValue }
}

extension MouseEventTapLocation: CaseIterable, InteractiveMenuValue {
    public static var allCases: [MouseEventTapLocation] { [.all, .hid, .session, .annotated] }
    var interactiveTitle: String { rawValue }
}

extension AXElementAction: CaseIterable, InteractiveMenuValue {
    public static var allCases: [AXElementAction] {
        [.press, .showMenu, .pick, .confirm, .cancel, .open, .increment, .decrement, .scrollToVisible]
    }

    var interactiveTitle: String { rawValue }
}

extension AXScrollDirection: CaseIterable, InteractiveMenuValue {
    public static var allCases: [AXScrollDirection] { [.up, .down, .left, .right] }
    var interactiveTitle: String { rawValue }
}

private enum AXElementEventKind: String, CaseIterable, InteractiveMenuValue {
    case action
    case focus
    case setValue
    case setSelectedText
    case scroll

    var interactiveTitle: String { rawValue }
}

extension Bool: InteractiveMenuValue {
    static var interactiveOptions: [Bool] { [false, true] }
    var interactiveTitle: String { self ? "yes" : "no" }
}

private extension pid_t {
    func nonZeroOrPrompt(_ io: InteractiveCLIIO) async throws -> pid_t {
        if self != 0 {
            return self
        }
        let raw = try await io.promptRequired("PID: ")
        guard let parsed = Int32(raw), parsed > 0 else {
            throw UsageError("invalid pid: \(raw)")
        }
        return pid_t(parsed)
    }
}
