import Testing
@testable import Shell

@Suite("Chip input layout")
struct ChipInputLayoutTests {
    @Test("input keeps the single-line minimum height")
    func visibleHeightKeepsMinimum() {
        #expect(ChipInputLayout.visibleHeight(for: 0) == ChipInputLayout.minVisibleHeight)
    }

    @Test("input grows until the scroll threshold")
    func visibleHeightGrowsUntilThreshold() {
        let middle = (ChipInputLayout.minVisibleHeight + ChipInputLayout.maxVisibleHeight) / 2

        #expect(abs(ChipInputLayout.visibleHeight(for: middle) - middle) < 0.001)
    }

    @Test("input caps visible height so overflow can scroll")
    func visibleHeightCapsAtThreshold() {
        #expect(ChipInputLayout.visibleHeight(for: ChipInputLayout.maxVisibleHeight + 40) == ChipInputLayout.maxVisibleHeight)
    }
}
