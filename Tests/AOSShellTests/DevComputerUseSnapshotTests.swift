import AOSComputerUseKit
import CoreGraphics
import Testing
@testable import AOSShell

@Suite("Dev Computer Use snapshot")
struct DevComputerUseSnapshotTests {
    @Test("app and window summaries expose diagnostic identity")
    func appAndWindowSummaries() {
        let app = AppInfo(
            pid: 4242,
            bundleId: "com.example.Editor",
            name: "Editor",
            path: "/Applications/Editor.app",
            running: true,
            active: true
        )
        let window = WindowInfo(
            id: CGWindowID(99),
            pid: 4242,
            owner: "Editor",
            title: "Draft.md",
            bounds: WindowBounds(x: 12, y: 34, width: 800, height: 600),
            zIndex: 7,
            isOnScreen: true,
            layer: 0
        )
        let snapshot = DevComputerUseSnapshot(apps: [app], windows: [window], state: nil)

        #expect(snapshot.appCountLine == "1 running app")
        #expect(snapshot.windowCountLine == "1 window")
        #expect(DevComputerUseSnapshot.appLine(app) == "Editor (com.example.Editor, pid 4242, active)")
        #expect(DevComputerUseSnapshot.windowLine(window) == "Draft.md (#99, 800x600, z 7)")
        #expect(DevComputerUseSnapshot.windowDetailLine(window) == "x 12, y 34, layer 0, onScreen true")
    }

    @Test("empty and missing state lines are explicit")
    func emptyStateLines() {
        let snapshot = DevComputerUseSnapshot(apps: [], windows: [], state: nil)
        let state = DevComputerUseStateSnapshot(
            stateId: "state-empty",
            appName: nil,
            bundleId: nil,
            elementCount: 0,
            treeMarkdown: "",
            screenshot: nil
        )

        #expect(snapshot.appCountLine == "0 running apps")
        #expect(snapshot.windowCountLine == "0 windows")
        #expect(state.identityLine == "Unknown app")
        #expect(state.axLine == "state state-empty, 0 elements")
    }

    @Test("state and screenshot summaries include ids, counts, and downscale metadata")
    func stateAndScreenshotSummaries() {
        let screenshot = DevComputerUseScreenshotSnapshot(
            width: 640,
            height: 360,
            byteCount: 12345,
            format: "png",
            originalWidth: 1280,
            originalHeight: 720
        )
        let state = DevComputerUseStateSnapshot(
            stateId: "state-1",
            appName: "Editor",
            bundleId: "com.example.Editor",
            elementCount: 3,
            treeMarkdown: "tree",
            screenshot: screenshot
        )

        #expect(state.identityLine == "Editor (com.example.Editor)")
        #expect(state.axLine == "state state-1, 3 elements")
        #expect(screenshot.line == "640x360 PNG, 12345 bytes (downscaled from 1280x720)")
    }
}
