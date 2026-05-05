import Testing
import Foundation
import CoreGraphics
@testable import AOSOSSenseKit

@MainActor
@Suite("SenseStore — multi-source behaviors merge")
struct SenseStoreBehaviorMergeTests {

    private func makeStore() -> SenseStore {
        SenseStore(
            permissionsService: PermissionsService(),
            registry: AdapterRegistry()
        )
    }

    private func envelope(kind: String, key: String, summary: String) -> BehaviorEnvelope {
        BehaviorEnvelope(
            kind: kind,
            citationKey: key,
            displaySummary: summary,
            payload: .object([:])
        )
    }

    @Test("General source populates context.behaviors")
    func generalEmits() {
        let store = makeStore()
        let env = envelope(kind: "general.selectedText", key: "g:1", summary: "hi")
        store._applyBehaviorsForTesting(source: "general", envelopes: [env])
        #expect(store.context.behaviors.count == 1)
        #expect(store.context.behaviors.first?.citationKey == "g:1")
    }

    @Test("General appears before adapter contributions")
    func generalFirst() {
        let store = makeStore()
        let g = envelope(kind: "general.selectedText", key: "g:1", summary: "hi")
        let a = envelope(kind: "finder.selection", key: "a:1", summary: "files")
        store._applyBehaviorsForTesting(source: "finder", envelopes: [a])
        store._applyBehaviorsForTesting(source: "general", envelopes: [g])
        let kinds = store.context.behaviors.map(\.kind)
        #expect(kinds.first == "general.selectedText")
        #expect(kinds.contains("finder.selection"))
    }

    @Test("Finder selection suppresses only the degraded general selectedItems")
    func finderSelectionSuppressesGeneralSelectedItems() {
        let store = makeStore()
        let selectedItems = envelope(
            kind: "general.selectedItems",
            key: "general.selectedItems:100",
            summary: "AXGroup"
        )
        let selectedText = envelope(
            kind: "general.selectedText",
            key: "general.selectedText:100",
            summary: "text"
        )
        let finder = envelope(
            kind: "finder.selection",
            key: "finder.selection",
            summary: "Finder · Report.pdf"
        )

        store._applyBehaviorsForTesting(source: "general", envelopes: [selectedItems, selectedText])
        store._applyBehaviorsForTesting(source: "finder", envelopes: [finder])

        #expect(store.context.behaviors.map(\.kind) == [
            "general.selectedText",
            "finder.selection",
        ])
    }

    @Test("Empty emit removes that source's contribution")
    func emptyRemovesSource() {
        let store = makeStore()
        let g = envelope(kind: "general.selectedText", key: "g:1", summary: "x")
        store._applyBehaviorsForTesting(source: "general", envelopes: [g])
        #expect(store.context.behaviors.count == 1)

        store._applyBehaviorsForTesting(source: "general", envelopes: [])
        #expect(store.context.behaviors.isEmpty)
        #expect(store._behaviorsBySourceForTesting["general"] == nil)
    }

    @Test("App switch clears all per-app behaviors and resets the slot")
    func appSwitchClears() {
        let store = makeStore()
        let g = envelope(kind: "general.selectedText", key: "g:1", summary: "x")
        store._applyBehaviorsForTesting(source: "general", envelopes: [g])
        // Apply a frontmost app first, then switch to a different one.
        store._applyFrontmostForTesting(
            app: AppIdentity(bundleId: "com.a", name: "A", pid: 1, icon: nil),
            window: WindowIdentity(title: "A", windowId: nil)
        )
        // Re-apply behaviors after the app set so they're attributed to pid 1.
        store._applyBehaviorsForTesting(source: "general", envelopes: [g])

        store._applyFrontmostForTesting(
            app: AppIdentity(bundleId: "com.b", name: "B", pid: 2, icon: nil),
            window: WindowIdentity(title: "B", windowId: nil)
        )
        #expect(store.context.behaviors.isEmpty)
        #expect(store._behaviorsBySourceForTesting.isEmpty)
    }

    @Test("visualSnapshotAvailable requires app + screen-recording grant")
    func visualSnapshotAvailability() {
        let store = makeStore()
        // No frontmost app, no permission state set — unavailable.
        #expect(!store.visualSnapshotAvailable)

        // Frontmost app, but Screen Recording denied → still unavailable.
        store._applyFrontmostForTesting(
            app: AppIdentity(bundleId: "com.x", name: "X", pid: 1, icon: nil),
            window: WindowIdentity(title: "X", windowId: nil)
        )
        store._applyPermissionsForTesting(PermissionState(denied: [.screenRecording]))
        #expect(!store.visualSnapshotAvailable)

        // Permission flips on → now available. Capture itself only happens
        // when the caller asks (submit-time); the flag just gates the chip.
        store._applyPermissionsForTesting(PermissionState(denied: []))
        #expect(store.visualSnapshotAvailable)
    }
}
