import AOSComputerUseKit
import AOSRPCSchema
import CoreGraphics
import Testing
@testable import AOSShell

@Suite("Computer Use RPC service")
struct ComputerUseRPCServiceTests {
    @Test("handleListApps maps mode and returns wire apps")
    func handleListApps() async throws {
        let core = FakeShellComputerUseClient()
        await core.setApps([
            AppInfo(
                pid: 123,
                bundleId: "com.example.Editor",
                name: "Editor",
                path: "/Applications/Editor.app",
                running: true,
                active: true
            ),
        ])
        let service = ComputerUseRPCService(core: core)

        let result = try await service.handleListApps(
            ComputerUseListAppsParams(mode: .running)
        )

        #expect(await core.calls == ["listApps:running"])
        #expect(result.apps.map(\.name) == ["Editor"])
        #expect(result.apps.first?.pid == 123)
    }

    @Test("handleUseMouse maps click payload into background mouse event")
    func handleUseMouse() async throws {
        let core = FakeShellComputerUseClient()
        let service = ComputerUseRPCService(core: core)

        _ = try await service.handlePostMouseEvent(
            ComputerUsePostMouseEventParams(
                windowId: 77,
                event: .click(
                    ComputerUseMouseClickEvent(
                        button: .left,
                        point: ComputerUsePoint(x: 12, y: 34),
                        count: 2
                    )
                )
            )
        )

        #expect(await core.calls == ["postMouseEvent:77:left click at 12,34 x2"])
    }

    @Test("handlePerformAXAction maps semantic AX action payload")
    func handlePerformAXAction() async throws {
        let core = FakeShellComputerUseClient()
        let service = ComputerUseRPCService(core: core)

        _ = try await service.handlePostEventToAXElement(
            ComputerUsePostEventToAXElementParams(
                windowId: 77,
                stateId: "state-1",
                elementIndex: 9,
                event: .action(ComputerUseAXActionEvent(action: .press))
            )
        )

        #expect(await core.calls == ["postEventToAXElement:77:state-1:9:action(press)"])
    }

    @Test("handleStopAppSession returns no-op when there is no active app session")
    func handleStopAppSessionWithoutActiveSession() async throws {
        let core = FakeShellComputerUseClient()
        await core.setCurrentAppSessionError(ComputerUseError.appSessionUnavailable("no active app session"))
        let service = ComputerUseRPCService(core: core)

        let result = try await service.handleStopAppSession(ComputerUseStopAppSessionParams(pid: 123))

        #expect(await core.calls == ["currentAppSession"])
        #expect(result.stopped == false)
        #expect(result.pid == nil)
    }

    @Test("handleStopAppSession bubbles unexpected current app session errors")
    func handleStopAppSessionBubblesUnexpectedCurrentSessionErrors() async throws {
        let core = FakeShellComputerUseClient()
        await core.setCurrentAppSessionError(ComputerUseRPCTestError.boom)
        let service = ComputerUseRPCService(core: core)

        do {
            _ = try await service.handleStopAppSession(ComputerUseStopAppSessionParams(pid: 123))
            Issue.record("unexpected current app session errors must bubble")
        } catch ComputerUseRPCTestError.boom {
            #expect(await core.calls == ["currentAppSession"])
        }
    }

    @Test("handleStopAppSession returns no-op when active app session pid does not match")
    func handleStopAppSessionWithDifferentActiveSession() async throws {
        let core = FakeShellComputerUseClient()
        await core.setActiveAppSession(AppSessionResult(pid: 999))
        let service = ComputerUseRPCService(core: core)

        let result = try await service.handleStopAppSession(ComputerUseStopAppSessionParams(pid: 123))

        #expect(await core.calls == ["currentAppSession"])
        #expect(result.stopped == false)
        #expect(result.pid == 999)
    }

    @Test("handleStopAppSession stops only when an active app session exists")
    func handleStopAppSessionWithActiveSession() async throws {
        let core = FakeShellComputerUseClient()
        await core.setActiveAppSession(AppSessionResult(pid: 123))
        let service = ComputerUseRPCService(core: core)

        let result = try await service.handleStopAppSession(ComputerUseStopAppSessionParams(pid: 123))

        #expect(await core.calls == ["currentAppSession", "stopAppSession"])
        #expect(result.stopped == true)
        #expect(result.pid == 123)
    }
}

private actor FakeShellComputerUseClient: ShellComputerUseClient {
    private(set) var calls: [String] = []
    private var apps: [AppInfo] = []
    private var activeAppSession: AppSessionResult?
    private var currentAppSessionError: Error?

    func setApps(_ apps: [AppInfo]) {
        self.apps = apps
    }

    func setActiveAppSession(_ session: AppSessionResult?) {
        self.activeAppSession = session
    }

    func setCurrentAppSessionError(_ error: Error) {
        self.currentAppSessionError = error
    }

    func listApps(mode: AppListMode) async throws -> [AppInfo] {
        calls.append("listApps:\(mode.rawValue)")
        return apps
    }

    func listWindows(pid: pid_t) async throws -> [WindowInfo] {
        calls.append("listWindows:\(pid)")
        return []
    }

    func getAppState(
        windowId: CGWindowID,
        captureMode: CaptureMode,
        maxImageDimension: Int
    ) async throws -> AppStateBundle {
        calls.append("getAppState:\(windowId):\(captureMode.rawValue):\(maxImageDimension)")
        return AppStateBundle(
            pid: 123,
            stateId: StateID("state"),
            treeMarkdown: "",
            elementCount: 0,
            screenshot: nil,
            bundleId: nil,
            appName: nil
        )
    }

    func startAppSession(pid: pid_t, windowId: CGWindowID) async throws -> AppSessionResult {
        calls.append("startAppSession:\(pid):\(windowId)")
        return AppSessionResult(pid: pid)
    }

    func stopAppSession() async throws -> AppSessionResult {
        calls.append("stopAppSession")
        return AppSessionResult(pid: 123)
    }

    func currentAppSession() async throws -> AppSessionResult {
        calls.append("currentAppSession")
        if let currentAppSessionError {
            throw currentAppSessionError
        }
        guard let activeAppSession else {
            throw ComputerUseError.appSessionUnavailable("no active app session")
        }
        return activeAppSession
    }

    func postMouseEvent(
        windowId: CGWindowID,
        event: BackgroundMouseEvent
    ) async throws -> WindowMouseEventResult {
        calls.append("postMouseEvent:\(windowId):\(event)")
        return WindowMouseEventResult(pid: 123, windowId: windowId, event: event)
    }

    func postKeyboardEvent(
        windowId: CGWindowID,
        event: BackgroundKeyboardEvent
    ) async throws -> WindowKeyboardEventResult {
        calls.append("postKeyboardEvent:\(windowId):\(event)")
        return WindowKeyboardEventResult(pid: 123, windowId: windowId, event: event)
    }

    func postEventToAXElement(
        windowId: CGWindowID,
        stateId: StateID,
        elementIndex: Int,
        event: AXElementEvent
    ) async throws -> AXElementEventResult {
        calls.append("postEventToAXElement:\(windowId):\(stateId.raw):\(elementIndex):\(Self.describe(event))")
        return AXElementEventResult(
            pid: 123,
            windowId: windowId,
            stateId: stateId,
            elementIndex: elementIndex,
            event: event
        )
    }

    private static func describe(_ event: AXElementEvent) -> String {
        switch event {
        case .action(let action):
            return "action(\(action.rawValue))"
        case .setValue(let value):
            return "setValue(\(value))"
        case .setSelectedText(let value):
            return "setSelectedText(\(value))"
        case .focus:
            return "focus"
        case .scroll(let direction, let pages):
            return "scroll(\(direction.rawValue),\(pages))"
        }
    }
}

private enum ComputerUseRPCTestError: Error {
    case boom
}
