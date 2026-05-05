import Testing
import AOSOSSenseKit
@testable import AOSShell

@MainActor
@Suite("Dev OS Sense snapshot")
struct DevOSSenseSnapshotTests {
    @Test("snapshot mirrors the latest SenseContext fields for Dev Mode")
    func snapshotMirrorsSenseContext() {
        let context = SenseContext(
            app: AppIdentity(
                bundleId: "com.example.Editor",
                name: "Editor",
                pid: 4242,
                icon: nil
            ),
            window: WindowIdentity(title: "Draft.md", windowId: 99),
            behaviors: [
                BehaviorEnvelope(
                    kind: "general.currentInput",
                    citationKey: "input.current",
                    displaySummary: "Current input: hello",
                    payload: .object([
                        "value": .string("hello"),
                        "confidence": .double(0.75)
                    ])
                )
            ],
            permissions: PermissionState(denied: [.accessibility, .screenRecording])
        )

        let snapshot = DevOSSenseSnapshot(context: context)

        #expect(snapshot.appLine == "Editor (com.example.Editor, pid 4242)")
        #expect(snapshot.windowLine == "Draft.md (#99)")
        #expect(snapshot.permissionsLine == "Denied: Accessibility, Screen Recording")
        #expect(snapshot.behaviors.count == 1)
        #expect(snapshot.behaviors[0].kind == "general.currentInput")
        #expect(snapshot.behaviors[0].citationKey == "input.current")
        #expect(snapshot.behaviors[0].displaySummary == "Current input: hello")
        #expect(snapshot.behaviors[0].payloadText.contains("\"value\" : \"hello\""))
        #expect(snapshot.behaviors[0].payloadText.contains("\"confidence\" : 0.75"))
    }

    @Test("empty context is explicit instead of pretending data exists")
    func emptyContextUsesExplicitLines() {
        let snapshot = DevOSSenseSnapshot(context: .empty)

        #expect(snapshot.appLine == "No frontmost app")
        #expect(snapshot.windowLine == "No focused window")
        #expect(snapshot.permissionsLine == "Denied: none")
        #expect(snapshot.behaviors.isEmpty)
    }
}
