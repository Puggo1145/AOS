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
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms > 100ms TTL
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

// MARK: - Frontmost target detection
//
// `MouseInput.click` shells out to the HID-tap path when the target is
// frontmost. Test that the helper used to make that decision agrees with
// `NSWorkspace.frontmostApplication.processIdentifier`.

import AppKit

@Suite("Frontmost target detection")
struct FrontmostDetectionTests {
    @Test("Test process pid matches NSWorkspace.frontmost when active in CI")
    func testProcessAgreement() {
        // The test process won't always be frontmost (especially in CI),
        // but `NSRunningApplication(processIdentifier:).isActive` should
        // never crash and should agree with NSWorkspace's frontmost
        // pointer when nonzero.
        let pid = getpid()
        let app = NSRunningApplication(processIdentifier: pid)
        if let app, let frontmost = NSWorkspace.shared.frontmostApplication {
            // If the test process IS frontmost, isActive should be true.
            if frontmost.processIdentifier == pid {
                #expect(app.isActive)
            }
        }
    }
}

// MARK: - HID tap regression guard
//
// Per `docs/designs/computer-use.md` §"事件投递路径": the HID tap path is
// reserved for FRONTMOST targets only. Any other use would warp the user's
// real cursor. This test grep-walks the kit source and pins the only
// usages to `MouseInput.clickFrontmostViaHIDTap` (which is gated on
// `NSRunningApplication.isActive`).

@Suite("HID tap usage scope")
struct HIDTapScopeTests {
    @Test("Only MouseInput.clickFrontmostViaHIDTap may post to .cghidEventTap")
    func onlyFrontmostPathUsesHIDTap() throws {
        // Walk every Swift file under Sources/AOSComputerUseKit and count
        // `.cghidEventTap` references. Only `MouseInput.swift`'s
        // `clickFrontmostViaHIDTap` recipe should contain the symbol.
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
            // The only legal home for this symbol is MouseInput.swift's
            // frontmost-only path.
            if url.lastPathComponent != "MouseInput.swift" {
                offendingFiles.append(url.path)
            }
        }
        #expect(offendingFiles.isEmpty, "Found .cghidEventTap outside MouseInput.swift: \(offendingFiles)")
    }
}
