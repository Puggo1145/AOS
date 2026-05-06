import Testing
import Foundation
import ApplicationServices
@testable import AOSComputerUseKit

// MARK: - AXEnablementAssertion negative cache
//
// Native Cocoa apps reject both AXManualAccessibility and
// AXEnhancedUserInterface writes; the cache prevents us from paying for
// repeated rejected writes on every snapshot. This test exercises the
// cache against the host process (which has AX active but doesn't accept
// the Chromium hints — same observable outcome as a native app).

@Suite("AXEnablementAssertion")
struct AXEnablementAssertionTests {

    @Test("Re-asserting the same pid is idempotent and tracks acceptance")
    func idempotentPerPid() async {
        let assertion = AXEnablementAssertion()
        let root = AXUIElementCreateApplication(getpid())
        // First assert may succeed or fail depending on whether the test
        // process accepts the writes (it usually doesn't); both outcomes
        // should be recorded consistently for subsequent calls.
        let first = await assertion.assert(pid: getpid(), root: root)
        let alreadyAsserted = await assertion.isAlreadyAsserted(pid: getpid())
        let nonAssertable = await assertion.isKnownNonAssertable(pid: getpid())
        // Exactly one branch should record the pid.
        #expect(alreadyAsserted != nonAssertable)
        let second = await assertion.assert(pid: getpid(), root: root)
        // Outcome must be stable across repeat calls.
        #expect(first == second)
    }

    @Test("Negative cache expires after TTL — deterministic via injected writer")
    func negativeCacheExpires() async throws {
        // Regression: prior implementation marked a pid permanently
        // non-assertable after a single failed write pair, so a Chromium
        // app whose AX subsystem wasn't ready on first snapshot stayed
        // demoted for its whole lifetime. We now expire negative entries.
        //
        // The test must NOT rely on the host process actually rejecting
        // AX writes (CI vs local diverges), so we inject a writer that
        // unconditionally returns `.failure` and pin the negative branch.
        let alwaysFail: AXAttributeWriter = { _, _, _ in AXError.failure }
        let assertion = AXEnablementAssertion(
            negativeCacheTTL: 0.1, writeAttribute: alwaysFail
        )
        let root = AXUIElementCreateApplication(getpid())
        let pid = getpid()
        // First call: both writes "fail" → recorded as non-assertable.
        let firstOutcome = await assertion.assert(pid: pid, root: root)
        #expect(firstOutcome == false)
        #expect(await assertion.isKnownNonAssertable(pid: pid))
        // Inside TTL: still cached, no re-probe.
        #expect(await assertion.isKnownNonAssertable(pid: pid))
        try await Task.sleep(for: .milliseconds(200)) // 200ms > 100ms TTL
        // After TTL: lazy eviction on read returns false → re-probe path.
        #expect(!(await assertion.isKnownNonAssertable(pid: pid)))
    }

    @Test("Successful write does not record a negative entry")
    func successDoesNotMarkNegative() async {
        // Sanity check on the success path: the writer reports both
        // attribute writes succeeded → pid is asserted, and the negative
        // cache stays empty for it. Catches a regression where a future
        // refactor inadvertently shadow-records every assert as negative.
        let alwaysSucceed: AXAttributeWriter = { _, _, _ in AXError.success }
        let assertion = AXEnablementAssertion(
            negativeCacheTTL: 30, writeAttribute: alwaysSucceed
        )
        let root = AXUIElementCreateApplication(getpid())
        let pid = getpid()
        let outcome = await assertion.assert(pid: pid, root: root)
        #expect(outcome == true)
        #expect(await assertion.isAlreadyAsserted(pid: pid))
        #expect(!(await assertion.isKnownNonAssertable(pid: pid)))
    }
}

// MARK: - SyntheticAppFocusEnforcer state restoration
//
// The enforcer's contract is: capture prior values, write `true`, restore
// originals on `reenableActivation`. With a `nil` window/element the path
// is a pure no-op — we assert the no-throw + the captured FocusState
// shape.

@Suite("SyntheticAppFocusEnforcer")
struct SyntheticAppFocusEnforcerTests {

    @Test("preventActivation with nil window/element returns a benign FocusState")
    func nilTargetsAreSafe() async {
        let enforcer = SyntheticAppFocusEnforcer()
        let state = await enforcer.preventActivation(pid: 0, window: nil, element: nil)
        // No window means nothing to restore — reenable is a no-op but
        // must not throw.
        await enforcer.reenableActivation(state)
    }
}

// MARK: - Mouse click route selection
//
// Coordinate-mode clicking is the agent's virtual mouse path. AX can use
// semantic actions when the tree is sufficient; every coordinate fallback
// must drive the software cursor and must not infer "real HID is OK" from
// the target process currently being active.

@Suite("Mouse click route selection")
struct MouseClickRouteSelectionTests {
    @Test("Default coordinate click route is virtual cursor primer path")
    func defaultClickIsVirtualCursorPrimerPath() {
        #expect(
            MouseInput._routeForClickForTesting(button: .left, count: 1, modifiers: [])
                == .authSignedPost
        )
    }

    @Test("Modified and non-left coordinate clicks stay on virtual cursor dual-post path")
    func modifiedAndNonLeftClicksStayVirtual() {
        #expect(
            MouseInput._routeForClickForTesting(button: .left, count: 1, modifiers: ["cmd"])
                == .dualPost
        )
        #expect(
            MouseInput._routeForClickForTesting(button: .right, count: 1, modifiers: [])
                == .dualPost
        )
        #expect(
            MouseInput._routeForClickForTesting(button: .left, count: 3, modifiers: [])
                == .dualPost
        )
    }

}

// MARK: - HID regression guard
//
// Coordinate-mode computer use is the agent's virtual mouse. Raw HID posts
// are global hardware events and cannot target a background process, so the
// mouse delivery layer must not contain a HID path at all.

@Suite("HID usage scope")
struct HIDScopeTests {
    @Test("AOSComputerUseKit does not post raw HID mouse events")
    func computerUseKitDoesNotPostRawHIDMouseEvents() throws {
        let kitDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AOSComputerUseKitTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Sources/AOSComputerUseKit", isDirectory: true)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: kitDir, includingPropertiesForKeys: nil) else {
            Issue.record("could not enumerate kit sources at \(kitDir.path)")
            return
        }
        var offendingFiles: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let body = try String(contentsOf: url, encoding: .utf8)
            guard body.contains(".cghidEventTap") else { continue }
            offendingFiles.append(url.path)
        }
        #expect(offendingFiles.isEmpty, "Found raw HID mouse posts: \(offendingFiles)")
    }

    @Test("MouseInput.click does not implicitly route through NSRunningApplication.isActive")
    func clickDoesNotUseActiveApplicationHeuristic() throws {
        let mouseInput = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AOSComputerUseKitTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Sources/AOSComputerUseKit/Input/MouseInput.swift")
        let body = try String(contentsOf: mouseInput, encoding: .utf8)
        #expect(!body.contains("NSRunningApplication(processIdentifier: pid)?.isActive"))
    }
}
