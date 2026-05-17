import ComputerUseKit
import RPCSchema
import CoreGraphics
import Foundation
import Testing
@testable import Shell

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
                stateId: "state-1",
                event: .click(
                    ComputerUseMouseClickEvent(
                        button: .left,
                        point: ComputerUsePoint(x: 12, y: 34),
                        count: 2
                    )
                )
            )
        )

        #expect(await core.calls == ["postMouseEvent:77:state-1:left click at 12,34 x2"])
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

    @Test("handleGetAppState writes screenshot bytes to .notch-agent tmp and returns a file reference")
    func handleGetAppStateWritesScreenshotFileReference() async throws {
        let core = FakeShellComputerUseClient()
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-agent-rpc-screenshot-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(".notch-agent", isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
        await core.setAppState(AppStateBundle(
            pid: 123,
            stateId: StateID("state-ref"),
            treeMarkdown: "",
            elementCount: 0,
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
            bundleId: nil,
            appName: nil
        ))
        let service = ComputerUseRPCService(
            core: core,
            screenshotStore: ScreenshotFileStore(directory: tmpDir)
        )

        let result = try await service.handleGetAppState(
            ComputerUseGetAppStateParams(windowId: 77, captureMode: .vision)
        )

        let imagePath = try #require(result.screenshot?.imagePath)
        #expect(imagePath.hasPrefix(tmpDir.path))
        #expect(imagePath.contains(".notch-agent/tmp/computer-use-state-ref-"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: imagePath)) == Data([1, 2, 3]))
    }
}

private actor FakeShellComputerUseClient: ShellComputerUseClient {
    private(set) var calls: [String] = []
    private var apps: [AppInfo] = []
    private var activeAppSession: AppSessionResult?
    private var currentAppSessionError: Error?
    private var appState: AppStateBundle?

    func setApps(_ apps: [AppInfo]) {
        self.apps = apps
    }

    func setActiveAppSession(_ session: AppSessionResult?) {
        self.activeAppSession = session
    }

    func setCurrentAppSessionError(_ error: Error) {
        self.currentAppSessionError = error
    }

    func setAppState(_ state: AppStateBundle) {
        self.appState = state
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
        captureMode: CaptureMode
    ) async throws -> AppStateBundle {
        calls.append("getAppState:\(windowId):\(captureMode.rawValue)")
        if let appState {
            return appState
        }
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
        stateId: StateID,
        event: BackgroundMouseEvent
    ) async throws -> WindowMouseEventResult {
        calls.append("postMouseEvent:\(windowId):\(stateId.raw):\(event)")
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
