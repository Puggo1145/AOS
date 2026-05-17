import Testing
@testable import Shell

@MainActor
@Suite("CompositionRoot boot state")
struct CompositionRootBootStateTests {
    @Test("new composition root starts idle")
    func newRootStartsIdle() {
        let root = CompositionRoot()
        #expect(root.bootState == .idle)
    }

    @Test("stop records explicit stopped boot state even before start")
    func stopRecordsStoppedState() {
        let root = CompositionRoot()
        root.stop()
        #expect(root.bootState == .stopped)
    }
}
