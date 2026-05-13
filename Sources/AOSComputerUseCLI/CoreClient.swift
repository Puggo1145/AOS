import AOSComputerUseKit
import CoreGraphics
import Darwin
import Foundation

public protocol ComputerUseCoreClient: Sendable {
    var diagnosticsClient: ComputerUseDiagnosticsClient { get }

    func listApps(mode: AppListMode) async throws -> [AppInfo]
    func getAppType(pid: pid_t) async throws -> AppTypeResult
    func listWindows(pid: pid_t) async throws -> [WindowInfo]
    func getAppState(
        pid: pid_t,
        windowId: CGWindowID,
        captureMode: CaptureMode,
        maxImageDimension: Int
    ) async throws -> AppStateBundle
    /// Starts an app session and keeps the target app visually active until stopped or switched.
    func startAppSession(pid: pid_t, windowId: CGWindowID) async throws -> AppSessionResult
    /// Stops the active app session and restores/deactivates according to the core session state.
    func stopAppSession() async throws -> AppSessionResult
    /// Returns the active app session without changing focus or window order.
    func currentAppSession() async throws -> AppSessionResult
    /// Posts a coordinate-based background mouse event in the active app session.
    func postMouseEvent(
        windowId: CGWindowID,
        event: BackgroundMouseEvent
    ) async throws -> WindowMouseEventResult
    /// Posts a pid-scoped background keyboard event in the active app session.
    func postKeyboardEvent(
        windowId: CGWindowID,
        event: BackgroundKeyboardEvent
    ) async throws -> WindowKeyboardEventResult
    /// Posts a semantic AX event to an element from a cached app-state snapshot.
    func postEventToAXElement(
        pid: pid_t,
        windowId: CGWindowID,
        stateId: StateID,
        elementIndex: Int,
        event: AXElementEvent
    ) async throws -> AXElementEventResult
}

public protocol ComputerUseDiagnosticsClient: Sendable {
    func focusWindowWithoutRaise(pid: pid_t, windowId: CGWindowID) async throws -> WindowFocusResult
    func postMouseEventTrace(
        windowId: CGWindowID,
        event: BackgroundMouseEvent
    ) async throws -> WindowMouseEventTraceResult
    func observeWindowOrder(
        pid: pid_t,
        windowId: CGWindowID,
        durationMilliseconds: Int,
        intervalMilliseconds: Int
    ) async throws -> [WindowOrderObservationSample]
}

extension ComputerUseDiagnostics: ComputerUseDiagnosticsClient {}

extension ComputerUseCore: ComputerUseCoreClient {
    public nonisolated var diagnosticsClient: ComputerUseDiagnosticsClient {
        diagnostics
    }
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
