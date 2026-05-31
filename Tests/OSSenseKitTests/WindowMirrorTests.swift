import Testing
import Foundation
import AppKit
@testable import OSSenseKit

@MainActor
private final class WindowMirrorTitleChangeFixture {
    private var titles = ["First Tab", "Second Tab"]
    private(set) var emissions: [(AppIdentity?, WindowIdentity?)] = []

    func nextSnapshot(element: AXUIElement) -> WindowMirror.FocusedWindowSnapshot {
        WindowMirror.FocusedWindowSnapshot(
            element: element,
            identity: WindowIdentity(title: titles.removeFirst(), windowId: 42)
        )
    }

    func record(app: AppIdentity?, window: WindowIdentity?) {
        emissions.append((app, window))
    }

    func reset() {
        emissions.removeAll()
    }
}

@Suite("WindowMirror — NSRunningApplication projection")
struct WindowMirrorTests {

    @Test("nil running app projects to (nil, nil)")
    func nilRunningApp() {
        let result = WindowMirror.project(runningApp: nil)
        #expect(result.app == nil)
        #expect(result.window == nil)
    }

    @Test("Currently-running app (this test process) projects with bundleId fallback chain")
    func selfProcessProjection() throws {
        // The test runner itself is an NSRunningApplication; it's the only
        // way to get a real instance without UI tests. We assert the shape
        // of the projection rather than fixed values, since the runner
        // identity differs across `swift test` invocations.
        let me = NSRunningApplication.current
        let projection = WindowMirror.project(runningApp: me)

        if me.bundleIdentifier == nil {
            // No bundle id → degraded to nil per spec.
            #expect(projection.app == nil)
            #expect(projection.window == nil)
        } else {
            let app = try #require(projection.app)
            let window = try #require(projection.window)
            #expect(app.bundleId == me.bundleIdentifier)
            #expect(app.pid == me.processIdentifier)
            // localizedName fallback: name is either localizedName or bundleId.
            #expect(app.name == (me.localizedName ?? me.bundleIdentifier))
            // window title mirrors app name; windowId is always nil at Stage 0.
            #expect(window.title == app.name)
            #expect(window.windowId == nil)
        }
    }

    @Test("Self-activation is suppressed: prior projection is preserved")
    func selfActivationSuppressed() async throws {
        let me = NSRunningApplication.current
        // `swift test` runs as `swiftpm-testing-helper`, an unbundled
        // executable, so `me.bundleIdentifier` is legitimately nil here.
        // Surface that as a recorded "this case isn't reachable" rather
        // than a silent pass — the test as written needs a bundled
        // host process and won't be exercised under SwiftPM. Logged so
        // CI dashboards can show "skipped because of host shape" rather
        // than masking it as a green check.
        guard let myBundleId = me.bundleIdentifier else {
            withKnownIssue("test runner has no bundleIdentifier — self-activation suppression cannot be validated under swift test") {
                Issue.record("skipped: bundleIdentifier nil under swift test runner")
            }
            return
        }

        // Configure the mirror to treat the test runner as "self".
        let mirror = await MainActor.run {
            WindowMirror(selfBundleId: myBundleId) { _, _ in }
        }

        // First, drive a non-self activation (nil → simulates a foreign app
        // that projects to nil because we cannot construct an arbitrary
        // NSRunningApplication; the contract under test is "self bundle does
        // not overwrite prior state", so any prior state — including
        // (nil, nil) — must survive a self-activation event).
        await mirror._applyFrontmostForTesting(nil)
        // Now activate "self" — must be a no-op against the projection.
        await mirror._applyFrontmostForTesting(me)

        let (app, window) = await MainActor.run { (mirror.app, mirror.window) }
        #expect(app == nil)
        #expect(window == nil)
    }

    @Test("AppIdentity equality ignores icon")
    func appIdentityEqualityIgnoresIcon() {
        let withIcon = AppIdentity(
            bundleId: "com.x.y",
            name: "Y",
            pid: 1,
            icon: NSImage(size: NSSize(width: 16, height: 16))
        )
        let withoutIcon = AppIdentity(
            bundleId: "com.x.y",
            name: "Y",
            pid: 1,
            icon: nil
        )
        #expect(withIcon == withoutIcon)
    }

    @Test("Focused window title changes re-emit current window without app switch")
    func focusedWindowTitleChangeReemitsCurrentWindow() async {
        let pid = getpid()
        let appElement = AXUIElementCreateApplication(pid)
        let windowElement = AXUIElementCreateApplication(pid)
        let app = AppIdentity(bundleId: "com.test.browser", name: "Browser", pid: pid, icon: nil)
        let fixture = await WindowMirrorTitleChangeFixture()

        let mirror = await MainActor.run {
            WindowMirror(
                hub: AXObserverHub(),
                focusedWindowReader: { _, _ in
                    fixture.nextSnapshot(element: windowElement)
                },
                appElementFactory: { _ in appElement },
                onChange: { app, window in
                    fixture.record(app: app, window: window)
                }
            )
        }

        await mirror.setAccessibilityGranted(true)
        await fixture.reset()
        await mirror._applyFrontmostForTesting(app: app)
        await mirror._dispatchFocusedWindowTitleChangedForTesting()

        let emissions = await fixture.emissions
        #expect(emissions.map { $0.1?.title } == ["First Tab", "Second Tab"])
        #expect(emissions.allSatisfy { $0.0 == app })
    }

    @Test("Manual refresh re-reads focused window title without AX notification")
    func manualRefreshReReadsFocusedWindowTitle() async {
        let pid = getpid()
        let appElement = AXUIElementCreateApplication(pid)
        let windowElement = AXUIElementCreateApplication(pid)
        let app = AppIdentity(bundleId: "com.test.preview", name: "Preview", pid: pid, icon: nil)
        let fixture = await WindowMirrorTitleChangeFixture()

        let mirror = await MainActor.run {
            WindowMirror(
                hub: AXObserverHub(),
                focusedWindowReader: { _, _ in
                    fixture.nextSnapshot(element: windowElement)
                },
                appElementFactory: { _ in appElement },
                onChange: { app, window in
                    fixture.record(app: app, window: window)
                }
            )
        }

        await mirror.setAccessibilityGranted(true)
        await fixture.reset()
        await mirror._applyFrontmostForTesting(app: app)
        await mirror.refresh()

        let emissions = await fixture.emissions
        #expect(emissions.map { $0.1?.title } == ["First Tab", "Second Tab"])
        #expect(emissions.allSatisfy { $0.0 == app })
    }
}
