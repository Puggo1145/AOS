import Testing
@testable import AOSComputerUseKit

@Suite("Visual cursor")
struct VisualCursorTests {
    @Test("software cursor hides one second after interaction")
    func softwareCursorIdleTimeout() {
        #expect(visualCursorPostInteractionIdleTimeout() == 1)
    }
}
