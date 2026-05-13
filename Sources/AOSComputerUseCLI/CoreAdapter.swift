import AOSComputerUseKit
import CoreGraphics
import Darwin
import Foundation

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
    /// Starts an app session and keeps the target app visually active until stopped or switched.
    func startAppSession(pid: pid_t, windowId: CGWindowID) async throws -> AppSessionResult
    /// Stops the active app session and restores/deactivates according to the core session state.
    func stopAppSession() async throws -> AppSessionResult
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

public enum TerminalKey: Sendable, Equatable {
    case up
    case down
    case left
    case right
    case confirm
    case character(String)
    case backspace
    case quit
}

public typealias PostCursorKey = TerminalKey

public protocol TerminalIO: Sendable {
    func write(_ text: String) async
    func readLine(prompt: String) async throws -> String
    func readKey() async throws -> TerminalKey
}

public protocol PostCursorIO: TerminalIO {}

public protocol InteractiveCLIIO: TerminalIO {
    func writeOutput(_ text: String) async
    func writeError(_ text: String) async
}

public protocol PostCursorOverlay: Sendable {
    func show(at point: CGPoint) async throws
    func move(to point: CGPoint) async throws
    func hide() async
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

    public func startAppSession(pid: pid_t, windowId: CGWindowID) async throws -> AppSessionResult {
        try await core.startAppSession(pid: pid, windowId: windowId)
    }

    public func stopAppSession() async throws -> AppSessionResult {
        try await core.stopAppSession()
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
