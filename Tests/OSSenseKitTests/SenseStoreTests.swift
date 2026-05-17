import Testing
import Foundation
@testable import OSSenseKit

@MainActor
@Suite("SenseStore — single-writer live mirror")
struct SenseStoreTests {

    private func makeStore() -> SenseStore {
        SenseStore(
            permissionsService: PermissionsService(),
            registry: AdapterRegistry()
        )
    }

    @Test("Initial context is .empty")
    func initialContextEmpty() {
        let store = makeStore()
        #expect(store.context == SenseContext.empty)
        #expect(store.context.app == nil)
        #expect(store.context.window == nil)
        #expect(store.context.behaviors.isEmpty)
        #expect(store.context.permissions.denied.isEmpty)
    }

    @Test("Frontmost projection updates app/window without disturbing other fields")
    func frontmostProjection() {
        let store = makeStore()
        let app = AppIdentity(
            bundleId: "com.apple.finder",
            name: "Finder",
            pid: 4242,
            icon: nil
        )
        let window = WindowIdentity(title: "Finder", windowId: nil)

        store._applyFrontmostForTesting(app: app, window: window)

        #expect(store.context.app == app)
        #expect(store.context.window == window)
        // Other fields preserved.
        #expect(store.context.behaviors.isEmpty)
        #expect(store.context.permissions.denied.isEmpty)
    }

    @Test("Live context follows frontmost changes and replaces stale behaviors")
    func liveContextFollowsFrontmostChanges() {
        let store = makeStore()
        let editor = AppIdentity(
            bundleId: "com.example.editor",
            name: "Editor",
            pid: 123,
            icon: nil
        )
        let finder = AppIdentity(
            bundleId: "com.apple.finder",
            name: "Finder",
            pid: 456,
            icon: nil
        )
        let editorWindow = WindowIdentity(title: "Draft", windowId: nil)
        let finderWindow = WindowIdentity(title: "Downloads", windowId: nil)
        let currentInput = BehaviorEnvelope(
            kind: "general.currentInput",
            citationKey: "general.currentInput:123",
            displaySummary: "Current input",
            payload: .object(["value": .string("draft")])
        )

        store._applyFrontmostForTesting(app: editor, window: editorWindow)
        store._applyBehaviorsForTesting(source: "general", envelopes: [currentInput])
        store._applyFrontmostForTesting(app: finder, window: finderWindow)

        #expect(store.context.app == finder)
        #expect(store.context.window == finderWindow)
        #expect(store.context.behaviors.isEmpty)
    }

    @Test("Permissions projection updates only the permissions slot")
    func permissionsProjection() {
        let store = makeStore()
        let app = AppIdentity(
            bundleId: "com.apple.Safari",
            name: "Safari",
            pid: 99,
            icon: nil
        )
        let window = WindowIdentity(title: "Safari", windowId: nil)
        store._applyFrontmostForTesting(app: app, window: window)

        let perms = PermissionState(denied: [.accessibility, .screenRecording])
        store._applyPermissionsForTesting(perms)

        #expect(store.context.permissions == perms)
        // Frontmost app/window survived.
        #expect(store.context.app == app)
        #expect(store.context.window == window)
    }

    @Test("Sequential writers don't corrupt state under MainActor isolation")
    func sequentialWritersConverge() async {
        let store = makeStore()

        for i in 0..<50 {
            let app = AppIdentity(
                bundleId: "com.example.app\(i)",
                name: "App\(i)",
                pid: pid_t(i),
                icon: nil
            )
            let window = WindowIdentity(title: "Win\(i)", windowId: nil)
            store._applyFrontmostForTesting(app: app, window: window)
        }

        // Final write wins — no torn state.
        #expect(store.context.app?.bundleId == "com.example.app49")
        #expect(store.context.window?.title == "Win49")
    }
}
