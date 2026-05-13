import AOSComputerUseKit
import CoreGraphics
import Darwin
import Foundation

struct ParsedCommand {
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
        case startAppSession(AppSessionTargetRequest)
        case stopAppSession
        case mouseEventCommand(MouseEventCommandRequest)
        case keyboardEventCommand(KeyboardEventCommandRequest)
        case measureLeftClickWindowOrder(LeftClickWindowOrderMeasurementRequest)
        case observeWindowOrder(WindowOrderObservationRequest)
        case observeMouseEvents(MouseEventObservationRequest)
        case postCursor(PostCursorRequest)
        case interactive
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
        case "start-app-session":
            let pid = try options.requiredPID("--pid")
            let windowId = try options.requiredWindowID("--window-id")
            try options.rejectUnused()
            command = .startAppSession(AppSessionTargetRequest(pid: pid, windowId: windowId))
        case "stop-app-session":
            try options.rejectUnused()
            command = .stopAppSession
        case "left-click":
            let windowId = try options.requiredWindowID("--window-id")
            let coordinate = try options.requiredPoint("--coor")
            let count = try options.optionalPositiveInt("--count") ?? 1
            let trace = try options.takeFlag("--trace")
            try options.rejectUnused()
            command = .mouseEventCommand(MouseEventCommandRequest(
                windowId: windowId,
                event: .click(button: .left, coordinate: coordinate, count: count),
                trace: trace
            ))
        case "right-click":
            let windowId = try options.requiredWindowID("--window-id")
            let coordinate = try options.requiredPoint("--coor")
            let count = try options.optionalPositiveInt("--count") ?? 1
            let trace = try options.takeFlag("--trace")
            try options.rejectUnused()
            command = .mouseEventCommand(MouseEventCommandRequest(
                windowId: windowId,
                event: .click(button: .right, coordinate: coordinate, count: count),
                trace: trace
            ))
        case "drag":
            let windowId = try options.requiredWindowID("--window-id")
            let start = try options.requiredPoint("--from")
            let end = try options.requiredPoint("--to")
            let button = try options.optionalEnum("--button", BackgroundMouseButton.self) ?? .left
            let trace = try options.takeFlag("--trace")
            try options.rejectUnused()
            command = .mouseEventCommand(MouseEventCommandRequest(
                windowId: windowId,
                event: .drag(button: button, start: start, end: end),
                trace: trace
            ))
        case "type-text":
            let windowId = try options.requiredWindowID("--window-id")
            let text = try options.requiredPublicString("--text")
            let delayMilliseconds = try options.optionalInt("--delay-ms") ?? 30
            try options.rejectUnused()
            command = .keyboardEventCommand(KeyboardEventCommandRequest(
                windowId: windowId,
                event: .text(text, delayMilliseconds: delayMilliseconds)
            ))
        case "press-key":
            let windowId = try options.requiredWindowID("--window-id")
            let key = try options.requiredPublicString("--key")
            let modifiers = try options.optionalModifierList("--modifiers")
            let count = try options.optionalPositiveInt("--count") ?? 1
            try options.rejectUnused()
            command = .keyboardEventCommand(KeyboardEventCommandRequest(
                windowId: windowId,
                event: .keyPress(key: key, modifiers: modifiers, count: count)
            ))
        case "hotkey":
            let windowId = try options.requiredWindowID("--window-id")
            let keys = try options.requiredKeyList("--keys")
            guard let key = keys.last else {
                throw UsageError("missing required option --keys")
            }
            let modifiers = try keys.dropLast().map { try BackgroundKeyboardModifier.cliValue($0) }
            try options.rejectUnused()
            command = .keyboardEventCommand(KeyboardEventCommandRequest(
                windowId: windowId,
                event: .hotkey(modifiers: modifiers, key: key)
            ))
        case "measure-left-click-window-order":
            let windowId = try options.requiredWindowID("--window-id")
            let coordinate = try options.requiredPoint("--coor")
            let runs = try options.optionalPositiveInt("--runs") ?? 10
            let durationMilliseconds = try options.optionalPositiveInt("--duration-ms") ?? 8_000
            let intervalMilliseconds = try options.optionalPositiveInt("--interval-ms") ?? 1
            let preClickDelayMilliseconds = try options.optionalInt("--pre-click-delay-ms") ?? 2_000
            let betweenRunsMilliseconds = try options.optionalInt("--between-runs-ms") ?? 300
            try options.rejectUnused()
            command = .measureLeftClickWindowOrder(LeftClickWindowOrderMeasurementRequest(
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
            let windowId = try options.optionalWindowID("--window-id")
            let coordinate = try options.optionalPoint("--coor")
            try options.rejectUnused()
            command = .postCursor(PostCursorRequest(windowId: windowId, coordinate: coordinate))
        case "interactive":
            try options.rejectUnused()
            command = .interactive
        default:
            throw UsageError("unknown command \(first). Run AOSComputerUseCLI --help")
        }
        self.outputFormat = outputFormat
    }
}

enum OutputFormat {
    case text
    case json
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

struct UsageError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }

    init(_ message: String) {
        self.message = message
    }
}

struct ComputerUseCLIInvariantError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }

    init(_ message: String) {
        self.message = message
    }
}

struct AppStateRequest: Sendable {
    let pid: pid_t
    let windowId: CGWindowID
    let captureMode: CaptureMode
    let maxImageDimension: Int
    let screenshotOutput: String?
}

struct FocusWindowRequest: Sendable {
    let pid: pid_t
    let windowId: CGWindowID
}

struct AppSessionTargetRequest: Sendable {
    let pid: pid_t
    let windowId: CGWindowID
}

struct MouseEventCommandRequest: Sendable {
    let windowId: CGWindowID
    let event: MouseEventCommand
    let trace: Bool
}

struct KeyboardEventCommandRequest: Sendable {
    let windowId: CGWindowID
    let event: BackgroundKeyboardEvent
}

enum MouseEventCommand: Sendable, Equatable {
    case click(button: BackgroundMouseButton, coordinate: CGPoint, count: Int = 1)
    case drag(button: BackgroundMouseButton, start: CGPoint, end: CGPoint)

    var commandName: String {
        switch self {
        case .click(.left, _, _):
            return "left-click"
        case .click(.right, _, _):
            return "right-click"
        case .drag:
            return "drag"
        }
    }
}

struct LeftClickWindowOrderMeasurementRequest: Sendable {
    let windowId: CGWindowID
    let coordinate: CGPoint
    let runs: Int
    let durationMilliseconds: Int
    let intervalMilliseconds: Int
    let preClickDelayMilliseconds: Int
    let betweenRunsMilliseconds: Int
}

struct PostCursorRequest: Sendable {
    let windowId: CGWindowID?
    let coordinate: CGPoint?
}

enum PostCursorEventKind: String, Sendable, Equatable {
    case leftClick = "left-click"
    case rightClick = "right-click"
    case drag
}

enum PostCursorPointAction: Sendable, Equatable {
    case confirm
    case quit
}

struct PostCursorResult: Sendable, Equatable {
    let pid: pid_t
    let windowId: CGWindowID
    let point: CGPoint
    let localPoint: CGPoint
    let eventKind: PostCursorEventKind
    let postedEventCount: Int
    let lastEvent: BackgroundMouseEvent?
}
