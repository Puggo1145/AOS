import ComputerUseKit
import CoreGraphics
import Darwin
import Foundation
import Testing
@testable import Shell

@Suite("Dev Computer Use service")
@MainActor
struct DevComputerUseServiceTests {
    @Test("selecting an app starts a session for its frontmost window and reads state")
    func selectingAppStartsSessionAndReadsState() async throws {
        let client = FakeDevComputerUseClient()
        await client.setApps([Self.app(pid: 123, name: "Editor")])
        await client.setWindows([
            Self.window(id: 10, pid: 123, zIndex: 1),
            Self.window(id: 20, pid: 123, zIndex: 9),
        ])
        let service = DevComputerUseService(client: client)

        await service.refreshApps()
        await service.selectApp(identity: "pid:123")

        #expect(service.selectedWindowId == 20)
        #expect(service.appState?.stateId == StateID("state-20"))
        #expect(await client.calls == [
            "listApps:running",
            "listWindows:123",
            "startAppSession:123:20",
            "getAppState:20:ax",
        ])
        #expect(service.lastError == nil)
    }

    @Test("switching apps stops the session started by the previous selection")
    func switchingAppsStopsPreviousSession() async throws {
        let client = FakeDevComputerUseClient()
        await client.setApps([
            Self.app(pid: 123, name: "Editor"),
            Self.app(pid: 456, name: "Browser"),
        ])
        await client.setWindows([
            Self.window(id: 20, pid: 123, zIndex: 9),
            Self.window(id: 30, pid: 456, zIndex: 4),
        ])
        let service = DevComputerUseService(client: client)

        await service.refreshApps()
        await service.selectApp(identity: "pid:123")
        await service.selectApp(identity: "pid:456")

        #expect(service.selectedWindowId == 30)
        #expect(await client.calls == [
            "listApps:running",
            "listWindows:123",
            "startAppSession:123:20",
            "getAppState:20:ax",
            "currentAppSession",
            "stopAppSession:123",
            "listWindows:456",
            "startAppSession:456:30",
            "getAppState:30:ax",
        ])
        #expect(service.lastError == nil)
    }

    @Test("clearing selection ends the session started by dev mode")
    func clearingSelectionStopsSession() async throws {
        let client = FakeDevComputerUseClient()
        await client.setApps([Self.app(pid: 123, name: "Editor")])
        await client.setWindows([Self.window(id: 20, pid: 123, zIndex: 9)])
        let service = DevComputerUseService(client: client)

        await service.refreshApps()
        await service.selectApp(identity: "pid:123")
        await service.clearSelection()

        #expect(service.selectedAppIdentity == nil)
        #expect(service.selectedWindowId == nil)
        #expect(service.windows.isEmpty)
        #expect(service.appState == nil)
        #expect(await client.calls == [
            "listApps:running",
            "listWindows:123",
            "startAppSession:123:20",
            "getAppState:20:ax",
            "currentAppSession",
            "stopAppSession:123",
        ])
        #expect(service.lastError == nil)
    }

    private static func app(pid: pid_t, name: String) -> AppInfo {
        AppInfo(
            pid: pid,
            bundleId: nil,
            name: name,
            path: nil,
            running: true,
            active: false
        )
    }

    private static func window(id: CGWindowID, pid: pid_t, zIndex: Int) -> WindowInfo {
        WindowInfo(
            id: id,
            pid: pid,
            owner: "Owner",
            title: "Window \(id)",
            bounds: WindowBounds(x: 0, y: 0, width: 100, height: 80),
            zIndex: zIndex,
            isOnScreen: true,
            layer: 0
        )
    }
}

private actor FakeDevComputerUseClient: ShellComputerUseClient {
    private(set) var calls: [String] = []
    private var apps: [AppInfo] = []
    private var windows: [WindowInfo] = []
    private var activeAppSession: AppSessionResult?

    func setApps(_ apps: [AppInfo]) {
        self.apps = apps
    }

    func setWindows(_ windows: [WindowInfo]) {
        self.windows = windows
    }

    func listApps(mode: AppListMode) async throws -> [AppInfo] {
        calls.append("listApps:\(mode.rawValue)")
        return apps
    }

    func listWindows(pid: pid_t) async throws -> [WindowInfo] {
        calls.append("listWindows:\(pid)")
        return windows.filter { $0.pid == pid }
    }

    func getAppState(
        windowId: CGWindowID,
        captureMode: CaptureMode
    ) async throws -> AppStateBundle {
        calls.append("getAppState:\(windowId):\(captureMode.rawValue)")
        guard let window = windows.first(where: { $0.id == windowId }) else {
            throw ComputerUseError.windowNotFound(windowId: windowId)
        }
        return AppStateBundle(
            pid: window.pid,
            stateId: StateID("state-\(windowId)"),
            treeMarkdown: "window \(windowId)",
            elementCount: Int(windowId),
            screenshot: nil,
            bundleId: nil,
            appName: window.owner
        )
    }

    func startAppSession(pid: pid_t, windowId: CGWindowID) async throws -> AppSessionResult {
        calls.append("startAppSession:\(pid):\(windowId)")
        let session = AppSessionResult(pid: pid)
        activeAppSession = session
        return session
    }

    func stopAppSession() async throws -> AppSessionResult {
        guard let activeAppSession else {
            throw ComputerUseError.appSessionUnavailable("no active app session")
        }
        calls.append("stopAppSession:\(activeAppSession.pid)")
        self.activeAppSession = nil
        return activeAppSession
    }

    func currentAppSession() async throws -> AppSessionResult {
        calls.append("currentAppSession")
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
        WindowMouseEventResult(pid: 0, windowId: windowId, event: event)
    }

    func postKeyboardEvent(
        windowId: CGWindowID,
        event: BackgroundKeyboardEvent
    ) async throws -> WindowKeyboardEventResult {
        WindowKeyboardEventResult(pid: 0, windowId: windowId, event: event)
    }

    func postEventToAXElement(
        windowId: CGWindowID,
        stateId: StateID,
        elementIndex: Int,
        event: AXElementEvent
    ) async throws -> AXElementEventResult {
        AXElementEventResult(
            pid: 0,
            windowId: windowId,
            stateId: stateId,
            elementIndex: elementIndex,
            event: event
        )
    }
}
