import CoreGraphics
import Testing
@testable import ComputerUseKit

@Suite("WindowEnumerator")
struct WindowEnumeratorTests {
    @Test("appWindows filters WindowServer helper strips from browser processes")
    func appWindowsFiltersHelperStrips() {
        let pid: pid_t = 24_358
        let usefulWindow = WindowInfo(
            id: 374_730,
            pid: pid,
            owner: "Browser",
            title: "拾荒者统治第3集-番剧-全集-高清正版在线观看-bilibili-哔哩哔哩",
            bounds: WindowBounds(x: 0, y: 33, width: 1512, height: 949),
            zIndex: 1_868,
            isOnScreen: true,
            layer: 0
        )
        let offscreenStrip = WindowInfo(
            id: 378_589,
            pid: pid,
            owner: "Browser",
            title: "",
            bounds: WindowBounds(x: -608, y: -1440, width: 2560, height: 30),
            zIndex: 2_935,
            isOnScreen: false,
            layer: 0
        )
        let topEdgeStrip = WindowInfo(
            id: 374_776,
            pid: pid,
            owner: "Browser",
            title: "",
            bounds: WindowBounds(x: 0, y: 0, width: 1512, height: 33),
            zIndex: 2_881,
            isOnScreen: false,
            layer: 0
        )
        let otherProcessWindow = WindowInfo(
            id: 1,
            pid: 99,
            owner: "Other",
            title: "Other",
            bounds: WindowBounds(x: 0, y: 0, width: 800, height: 600),
            zIndex: 1,
            isOnScreen: true,
            layer: 0
        )
        let panelLayerWindow = WindowInfo(
            id: 2,
            pid: pid,
            owner: "Browser",
            title: "Panel",
            bounds: WindowBounds(x: 0, y: 0, width: 800, height: 600),
            zIndex: 2,
            isOnScreen: true,
            layer: 8
        )

        let windows = WindowEnumerator.appWindows(
            forPid: pid,
            from: [
                offscreenStrip,
                topEdgeStrip,
                usefulWindow,
                otherProcessWindow,
                panelLayerWindow,
            ]
        )

        #expect(windows == [usefulWindow])
    }

    @Test("appWindows keeps untitled normal-size app windows")
    func appWindowsKeepsUntitledNormalSizeWindows() {
        let pid: pid_t = 42
        let untitledWindow = WindowInfo(
            id: 7,
            pid: pid,
            owner: "Fixture",
            title: "",
            bounds: WindowBounds(x: 100, y: 100, width: 640, height: 480),
            zIndex: 10,
            isOnScreen: true,
            layer: 0
        )

        let windows = WindowEnumerator.appWindows(forPid: pid, from: [untitledWindow])

        #expect(windows == [untitledWindow])
    }
}
