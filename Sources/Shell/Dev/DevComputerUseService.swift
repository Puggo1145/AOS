import ComputerUseKit
import CoreGraphics
import Darwin
import Foundation

// MARK: - DevComputerUseService
//
// Dev Mode adapter for the Shell-owned Computer Use core. It keeps the
// diagnostic UI stateful while leaving validation and OS operations inside
// ComputerUseCore via ShellComputerUseClient.

@MainActor
@Observable
final class DevComputerUseService {
    private(set) var apps: [AppInfo] = []
    private(set) var windows: [WindowInfo] = []
    private(set) var appState: AppStateBundle?
    private(set) var selectedAppIdentity: String?
    private(set) var selectedWindowId: CGWindowID?
    private(set) var lastError: String?
    var captureMode: CaptureMode = .ax

    @ObservationIgnored
    private let client: any ShellComputerUseClient
    private var startedSessionPID: pid_t?

    var selectedApp: AppInfo? {
        guard let selectedAppIdentity else { return nil }
        return apps.first { $0.identity == selectedAppIdentity }
    }

    init(client: any ShellComputerUseClient) {
        self.client = client
    }

    func refreshApps() async {
        await recordError {
            let runningApps = try await client.listApps(mode: .running)
            apps = runningApps.sorted {
                if $0.active != $1.active {
                    return $0.active && !$1.active
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

            if let selectedAppIdentity,
               !apps.contains(where: { $0.identity == selectedAppIdentity }) {
                try await clearSelectionImpl()
            }
        }
    }

    func selectApp(identity: String?) async {
        await recordError {
            guard identity != selectedAppIdentity else { return }
            try await clearSelectionImpl()
            guard let identity else { return }
            guard let app = apps.first(where: { $0.identity == identity }) else {
                throw DevComputerUseError.appSelectionNotFound(identity)
            }
            guard let pid = app.pid else {
                throw DevComputerUseError.runningAppRequiresPID(app.name)
            }

            selectedAppIdentity = identity
            windows = try await client.listWindows(pid: pid)
                .sorted { $0.zIndex > $1.zIndex }

            guard let window = windows.first else {
                return
            }
            try await startSession(pid: pid, windowId: window.id)
            try await refreshStateImpl(windowId: window.id)
        }
    }

    func selectWindow(id: CGWindowID?) async {
        await recordError {
            guard id != selectedWindowId else { return }
            appState = nil
            guard let id else {
                selectedWindowId = nil
                return
            }
            guard let app = selectedApp, let pid = app.pid else {
                throw DevComputerUseError.windowSelectionRequiresApp
            }
            guard windows.contains(where: { $0.id == id }) else {
                throw DevComputerUseError.windowSelectionNotFound(id)
            }
            try await startSession(pid: pid, windowId: id)
            try await refreshStateImpl(windowId: id)
        }
    }

    func refreshState() async {
        await recordError {
            guard let selectedWindowId else {
                throw DevComputerUseError.windowSelectionRequiresApp
            }
            try await refreshStateImpl(windowId: selectedWindowId)
        }
    }

    func setCaptureMode(_ mode: CaptureMode) async {
        captureMode = mode
        guard selectedWindowId != nil else { return }
        await refreshState()
    }

    func clearSelection() async {
        await recordError {
            try await clearSelectionImpl()
        }
    }

    private func startSession(pid: pid_t, windowId: CGWindowID) async throws {
        _ = try await client.startAppSession(pid: pid, windowId: windowId)
        startedSessionPID = pid
        selectedWindowId = windowId
    }

    private func refreshStateImpl(windowId: CGWindowID) async throws {
        appState = try await client.getAppState(
            windowId: windowId,
            captureMode: captureMode
        )
    }

    private func clearSelectionImpl() async throws {
        try await stopStartedSession()
        selectedAppIdentity = nil
        selectedWindowId = nil
        windows = []
        appState = nil
    }

    private func stopStartedSession() async throws {
        guard let startedSessionPID else { return }
        let active = try await client.currentAppSession()
        guard active.pid == startedSessionPID else {
            throw DevComputerUseError.activeSessionChanged(
                expected: startedSessionPID,
                actual: active.pid
            )
        }
        _ = try await client.stopAppSession()
        self.startedSessionPID = nil
    }

    private func recordError(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }
}

private enum DevComputerUseError: Error, CustomStringConvertible {
    case appSelectionNotFound(String)
    case runningAppRequiresPID(String)
    case windowSelectionRequiresApp
    case windowSelectionNotFound(CGWindowID)
    case activeSessionChanged(expected: pid_t, actual: pid_t)

    var description: String {
        switch self {
        case .appSelectionNotFound(let identity):
            return "selected app is not in the current app list: \(identity)"
        case .runningAppRequiresPID(let name):
            return "selected running app has no pid: \(name)"
        case .windowSelectionRequiresApp:
            return "select an app window before reading app state"
        case .windowSelectionNotFound(let windowId):
            return "selected window is not in the current app window list: \(windowId)"
        case .activeSessionChanged(let expected, let actual):
            return "active app session changed while Dev Mode owned pid \(expected): \(actual)"
        }
    }
}
