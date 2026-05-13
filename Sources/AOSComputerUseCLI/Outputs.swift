import AOSComputerUseKit
import CoreGraphics
import Darwin
import Foundation

protocol ReadableOutput {
    var readableText: String { get }
}

struct GrantPermissionsOutput: Encodable, ReadableOutput {
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

struct OpenCoorTestOutput: Encodable, ReadableOutput {
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

struct ListAppsOutput: Encodable, ReadableOutput {
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

struct AppInfoOutput: Encodable {
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

struct AppTypeOutput: Encodable, ReadableOutput {
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

struct ListWindowsOutput: Encodable, ReadableOutput {
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

struct WindowInfoOutput: Encodable {
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

struct AppStateOutput: Encodable, ReadableOutput {
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

struct FocusWindowOutput: Encodable, ReadableOutput {
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

struct StartAppSessionOutput: Encodable, ReadableOutput {
    let command = "start-app-session"
    let pid: pid_t
    let focusedWindowId: CGWindowID

    init(request: AppSessionTargetRequest, result: AppSessionResult) {
        self.pid = result.pid
        self.focusedWindowId = request.windowId
    }

    var readableText: String {
        "Started app session for pid \(pid), focused window \(focusedWindowId)."
    }
}

struct StopAppSessionOutput: Encodable, ReadableOutput {
    let command = "stop-app-session"
    let pid: pid_t

    init(result: AppSessionResult) {
        self.pid = result.pid
    }

    var readableText: String {
        "Stopped app session for pid \(pid)."
    }
}

struct MouseEventPostOutput: Encodable, ReadableOutput {
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
        case .click(_, let point, _):
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
        case .click(let button, _, let count):
            let base = "\(button.rawValue) click"
            return count == 1 ? base : "\(base) x\(count)"
        case .drag(let button, _, _):
            return "\(button.rawValue) drag"
        }
    }
}

struct KeyboardEventPostOutput: Encodable, ReadableOutput {
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

struct MouseEventTraceOutput: ReadableOutput {
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

struct LeftClickWindowOrderMeasurementOutput: Encodable, ReadableOutput {
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

    init(
        request: LeftClickWindowOrderMeasurementRequest,
        pid: pid_t,
        runs: [LeftClickWindowOrderMeasurementRun]
    ) {
        self.pid = pid
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

struct LeftClickWindowOrderMeasurementRun: Encodable {
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

struct WindowOrderObservationOutput: Encodable, ReadableOutput {
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

struct WindowOrderObservationStatistics: Encodable {
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

struct WindowOrderObservationDuration: Encodable {
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

struct WindowOrderObservationState: Equatable {
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

struct MouseEventObservationOutput: Encodable, ReadableOutput {
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

struct PostCursorOutput: Encodable, ReadableOutput {
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

struct PointOutput: Encodable {
    let x: Double
    let y: Double

    init(_ point: CGPoint) {
        self.x = point.x
        self.y = point.y
    }
}

struct ScreenshotOutput: Encodable {
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

struct CoordinateSpaceOutput: Encodable {
    let windowFrame: BoundsOutput
    let windowBounds: BoundsOutput
    let pixelSize: PixelSizeOutput

    init(_ coordinateSpace: ScreenshotCoordinateSpace) {
        self.windowFrame = BoundsOutput(coordinateSpace.windowFrame)
        self.windowBounds = BoundsOutput(coordinateSpace.windowBounds)
        self.pixelSize = PixelSizeOutput(coordinateSpace.pixelSize)
    }
}

struct BoundsOutput: Encodable {
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

struct PixelSizeOutput: Encodable {
    let width: Double
    let height: Double

    init(_ size: CGSize) {
        self.width = size.width
        self.height = size.height
    }
}
