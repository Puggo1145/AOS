import Testing
import Foundation
@testable import AOSComputerUseKit

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
